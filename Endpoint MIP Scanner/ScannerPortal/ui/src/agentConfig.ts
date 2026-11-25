import { SPHttpClient, SPHttpClientResponse } from '@microsoft/sp-http';
import { parseProfilePath, PublishedProfile, readPublishedProfile } from './profile';

export interface AgentProfile extends PublishedProfile {
  files: PublishedProfile['files'] & {
    'performance.json': { batchSize: number; pauseMilliseconds: number };
    'incremental.json': { enabled: boolean; rescanIntervalDays: number; detectModifiedFiles: boolean; detectDeletedFiles: boolean;
      forceFullScan: boolean; maxFileSizeMB: number; stateDirectory: string };
    'classifiers.json': { maxBytes: number; rules: { id: string; pattern: string }[] };
  };
}
export interface LoadedAgent { id: string; etag: string; profile: AgentProfile; path: string }
const guid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const quote = (v: string): string => encodeURIComponent("'" + v.replace(/'/g, "''") + "'");
async function check(response: SPHttpClientResponse): Promise<SPHttpClientResponse> {
  if (!response.ok) throw new Error(response.status === 412 ? 'The assignment changed. Reload this agent before publishing.' :
    'SharePoint returned HTTP ' + response.status + '. Check your permissions and reload the agent before retrying.');
  return response;
}
async function hash(content: ArrayBuffer): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', content)), b => ('0'+b.toString(16)).slice(-2)).join('').toUpperCase();
}
export class AgentConfigStore {
  private api: string;
  private library: string;
  public constructor(private client: SPHttpClient, web: string, relative: string, private ledger: string) {
    this.api = web + '/_api/web/';
    this.library = relative.replace(/\/$/, '') + '/ScannerPortalConfig/';
  }
  private get(url: string): Promise<SPHttpClientResponse> {
    return this.client.get(url, SPHttpClient.configurations.v1, { headers: { 'Cache-Control': 'no-cache' } }).then(check);
  }
  private post(url: string, body: string, headers: Record<string,string> = {}): Promise<SPHttpClientResponse> {
    return this.client.post(url, SPHttpClient.configurations.v1, { body, headers }).then(check);
  }
  private file(path: string): string {
    return this.api + 'GetFileByServerRelativePath(decodedurl=@p)/$value?@p=' + quote(this.library + path);
  }
  public async devices(): Promise<string[]> {
    const perms = await (await this.get(this.api+"lists/getByTitle('ScannerPortalConfig')/EffectiveBasePermissions")).json();
    const mask = Number((perms.EffectiveBasePermissions || perms).Low);
    if ((mask & 6) !== 6) throw new Error('Agent management requires add and edit access to ScannerPortalConfig.');
    let url = this.api + 'GetFolderByServerRelativePath(decodedurl=@p)/Files?@p=' + quote(this.library+'assignments') + '&$select=Name&$top=500';
    const ids: string[] = [];
    while (url) {
      const page = await (await this.get(url)).json();
      for (const file of page.value) {
        const id = String(file.Name).replace(/\.json$/i,'');
        if (guid.test(id) && /\.json$/i.test(file.Name)) ids.push(id);
      }
      url = page['@odata.nextLink'] || page['odata.nextLink'] || '';
      if (url && !url.startsWith(this.api)) throw new Error('Unexpected SharePoint paging URL.');
    }
    return ids.sort();
  }
  public async load(id: string): Promise<LoadedAgent> {
    if (!guid.test(id)) throw new Error('Invalid device registration.');
    const url = this.file('assignments/'+id+'.json');
    const meta = await (await this.get(url.replace('/$value?', '?')+'&$select=ETag')).json();
    const response = await this.get(url);
    const etag = response.headers.get('ETag') || meta.ETag || '';
    const assignment = await response.json();
    if (assignment.registrationId.toLowerCase() !== id.toLowerCase() || assignment.schemaVersion !== 1 ||
      parseProfilePath(assignment.profilePath).sha256 !== assignment.sha256.toUpperCase()) throw new Error('Invalid device assignment.');
    const data = await (await this.get(this.file(assignment.profilePath))).arrayBuffer();
    const profile = await readPublishedProfile(assignment.profilePath, data) as AgentProfile;
    return { id, etag, profile, path: assignment.profilePath };
  }
  public async publish(agent: LoadedAgent, draft: AgentProfile, rescan: boolean): Promise<LoadedAgent> {
    if (!agent.etag) throw new Error('SharePoint did not return an assignment ETag. Reload the agent.');
    const profile = JSON.parse(JSON.stringify(draft)) as AgentProfile;
    const suffix = crypto.randomUUID().replace(/-/g,'');
    const revisionTime = Date.now();
    profile.version = agent.profile.version.split('.').slice(0,2).join('.') + '.' + revisionTime;
    if (rescan) {
      if (profile.execution.paused || !profile.files['incremental.json'].enabled) throw new Error('Enable scanning and incremental state before requesting a rescan.');
      profile.files['incremental.json'].stateDirectory = '%LOCALAPPDATA%\\EndpointMIPScanner\\ManagedEndpoint\\rescan-' + revisionTime + '-' + suffix;
    }
    const json = JSON.stringify(profile);
    const bytes = new TextEncoder().encode(json);
    const digest = await hash(bytes.buffer);
    const parent = 'profiles/'+profile.profileId+'/'+profile.version;
    const path = parent+'/'+digest+'.json';
    await readPublishedProfile(path, bytes.buffer);
    // Reserve a new immutable version. A collision must fail before any file is written.
    await this.post(this.api+'folders/addUsingPath(decodedurl=@p,overwrite=false)?@p='+quote(this.library+parent),'');
    await this.post(this.api+'GetFolderByServerRelativePath(decodedurl=@p)/Files/add(url=@name,overwrite=false)?@p='+
      quote(this.library+parent)+'&@name='+quote(digest+'.json'), json, {'Content-Type':'application/octet-stream'});
    await readPublishedProfile(path, await (await this.get(this.file(path))).arrayBuffer());
    const assignment = { schemaVersion:1, registrationId:agent.id, profilePath:path, sha256:digest };
    await this.post(this.file('assignments/'+agent.id+'.json'), JSON.stringify(assignment),
      {'X-HTTP-Method':'PUT','IF-MATCH':agent.etag,'Content-Type':'application/octet-stream'});
    const saved = await this.load(agent.id);
    if (saved.path !== path) throw new Error('The active assignment differs from the published revision. Reload the agent.');
    return saved;
  }
  public async progress(agent: LoadedAgent): Promise<string> {
    if (!guid.test(this.ledger)) throw new Error('Configure the acceptance list GUID.');
    const digest = parseProfilePath(agent.path).sha256;
    const versionTime = Number(agent.profile.version.split('.')[2]);
    const since = new Date(versionTime - 300000).toISOString();
    let url = this.api+"lists(guid'"+this.ledger+"')/items?$select=Id,BatchId,ManifestSha256,SourceRelativePath,PortalReportJson&$filter="+
      encodeURIComponent("ReportingDeviceId eq '"+agent.id+"' and Created ge datetime'"+since+"'")+"&$orderby=Id asc&$top=100";
    const cycles: {id:number; generation:string; started:number; closed:boolean; errors:boolean}[] = [];
    while (url) {
      const page = await (await this.get(url)).json();
      for (const row of page.value) {
        const folder = 'devices/'+agent.id+'/batches/'+row.BatchId;
        if (!row.PortalReportJson || !/^[a-f0-9]{32}$/i.test(row.BatchId) || row.SourceRelativePath !== folder) continue;
        const landing = this.library.replace(/ScannerPortalConfig\/$/, 'ScannerPortalLanding/')+folder+'/';
        const readBytes = async (name:string):Promise<ArrayBuffer> => (await this.get(this.api+
          'GetFileByServerRelativePath(decodedurl=@p)/$value?@p='+quote(landing+name))).arrayBuffer();
        const manifestBytes = await readBytes('manifest.json');
        if (await hash(manifestBytes) !== row.ManifestSha256.toUpperCase()) throw new Error('The manifest differs from the accepted batch.');
        const manifest = JSON.parse(new TextDecoder().decode(manifestBytes));
        const entry = manifest.files.find((file:{name:string})=>file.name==='summary.json');
        const summaryBytes = await readBytes('summary.json');
        if (!entry || await hash(summaryBytes) !== entry.sha256.toUpperCase()) throw new Error('The accepted summary failed verification.');
        const wrapper = JSON.parse(new TextDecoder().decode(summaryBytes));
        if (wrapper.profileSha256?.toUpperCase() !== digest || wrapper.summary?.runId !== row.BatchId) continue;
        cycles.push({id:row.Id, generation:wrapper.summary.generation, started:Date.parse(wrapper.summary.startedUtc),
          closed:wrapper.summary.generationComplete, errors:wrapper.summary.generationHasErrors});
      }
      url = page['@odata.nextLink'] || page['odata.nextLink'] || '';
      if (url && !url.startsWith(this.api)) throw new Error('Unexpected SharePoint paging URL.');
    }
    if (!cycles.length) return 'Awaiting first accepted cycle';
    cycles.sort((a,b)=>a.started-b.started);
    const generation = cycles[0].generation;
    const firstScan = cycles.filter(c=>c.generation===generation);
    const closing = firstScan.find(c=>c.closed);
    const status = closing ? (closing.errors ? 'Completed with errors' : 'Completed') : 'In progress';
    return status+' · Generation '+generation+' · Acceptances '+firstScan.map(c=>c.id).join(', ');
  }
}
