import * as React from 'react';
import { SPHttpClient } from '@microsoft/sp-http';

interface Props { client: SPHttpClient; web: string; relative: string }
interface FileInfo { Name: string; TimeLastModified: string }
interface Row { id: string; received?: number }
const day = 86400000;
const idFile = /^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}\.json$/i;
const status = (row: Row, now: number): string => row.received === undefined ? 'Awaiting first contact' :
  now - row.received <= day ? 'Seen within 24 hours' : 'Over 24 hours';
const labels = ['Seen within 24 hours', 'Over 24 hours', 'Awaiting first contact'];
const quote = (s: string): string => encodeURIComponent("'" + s.replace(/'/g, "''") + "'");

async function files(p: Props, folder: string, optional: boolean): Promise<FileInfo[]> {
  const api = p.web + '/_api/web/';
  const path = p.relative.replace(/\/$/, '') + '/' + folder;
  let url = api + 'GetFolderByServerRelativePath(decodedurl=@p)/Files?@p=' + quote(path) + '&$select=Name,TimeLastModified&$top=500';
  const result: FileInfo[] = [];
  while (url) {
    const response = await p.client.get(url, SPHttpClient.configurations.v1, {headers:{'Cache-Control':'no-cache'}});
    if (optional && !result.length && response.status === 404) {
      const parent = await p.client.get(api + "lists/getByTitle('ScannerPortalLanding')?$select=Id", SPHttpClient.configurations.v1);
      if (parent.ok) return [];
    }
    if (!response.ok) throw new Error('Unable to read ' + folder + ' (HTTP ' + response.status + ').');
    const page = await response.json();
    for (const f of page.value) if (idFile.test(f.Name)) result.push(f);
    url = page['@odata.nextLink'] || page['odata.nextLink'] || '';
    if (url && !url.toLowerCase().startsWith(api.toLowerCase())) throw new Error('Unexpected SharePoint paging URL.');
  }
  return result;
}

export function FleetCoverage(p: Props): React.ReactElement {
  const [refresh, reload] = React.useState(0);
  const [rows, setRows] = React.useState<Row[]>();
  const [error, setError] = React.useState('');
  const [clock, setClock] = React.useState(Date.now());
  const [filter, setFilter] = React.useState('');
  const [page, setPage] = React.useState(0);
  const [detail, setDetail] = React.useState('');
  const seq = React.useRef(0);
  React.useEffect(() => {
    let active = true;
    const read = async (): Promise<void> => {
      try {
        const [assigned, signals] = await Promise.all([files(p,'ScannerPortalConfig/assignments',false),files(p,'ScannerPortalLanding/heartbeats',true)]);
        const times = new Map<string,number>();
        for (const f of signals) {
          const t = Date.parse(f.TimeLastModified);
          if (!Number.isFinite(t)) throw new Error('Invalid SharePoint receipt time.');
          times.set(f.Name.toLowerCase(),t);
        }
        if (active) {
          setClock(Date.now()); setError(''); setPage(0);
          setRows(assigned.map(f => ({id:f.Name.slice(0,-5).toLowerCase(),received:times.get(f.Name.toLowerCase())})).sort((a,b)=>a.id.localeCompare(b.id)));
        }
      } catch (e) { if (active) {setRows(undefined); setError(String(e));} }
    };
    void read();
    const timer = window.setInterval(() => reload(v=>v+1), 300000);
    return () => {active=false; window.clearInterval(timer);};
  },[p.client,p.web,p.relative,refresh]);
  async function show(id: string): Promise<void> {
    const request = ++seq.current;
    setDetail('Loading heartbeat…');
    try {
      const path = p.relative.replace(/\/$/,'') + '/ScannerPortalLanding/heartbeats/'+id+'.json';
      const r = await p.client.get(p.web+'/_api/web/GetFileByServerRelativePath(decodedurl=@p)/$value?@p='+quote(path),SPHttpClient.configurations.v1,{headers:{'Cache-Control':'no-cache'}});
      if (!r.ok) throw new Error('HTTP '+r.status);
      const h = await r.json();
      if (h.contract !== 'ScannerPortal.Heartbeat/1' || h.registrationId !== id) throw new Error('Heartbeat identity mismatch.');
      if (request===seq.current) setDetail([id, h.computer, 'Installed suite '+(h.suiteVersion || 'unknown'), 'Profile '+h.profileId+' '+h.profileVersion, h.state].join(' · '));
    } catch(e) { if(request===seq.current) setDetail('Unable to load heartbeat: '+String(e)); }
  }
  const selected = (rows || []).filter(r=>!filter || status(r,clock)===filter);
  return <section><h2>Fleet coverage</h2><p>Assigned registrations and their latest heartbeat received by SharePoint. Paused agents also check in.</p>
    <button onClick={()=>reload(v=>v+1)}>Refresh</button>
    {error && <p role="alert">{error}</p>}{!error && !rows && <p>Loading assigned agents…</p>}
    {rows && <><p>Assigned agents: <strong>{rows.length}</strong> · As of {new Date(clock).toISOString()}</p>
      <label>Contact status <select value={filter} onChange={e=>{setFilter(e.target.value);setPage(0);}}><option value="">All</option>
      {labels.map(s=><option key={s} value={s}>{s} ({rows.filter(r=>status(r,clock)===s).length})</option>)}</select></label>
      <table><thead><tr><th>Registration</th><th>Contact status</th><th>Last received (UTC)</th><th>Agent details</th></tr></thead>
      <tbody>{selected.slice(page*50,page*50+50).map(r=><tr key={r.id}><td>{r.id}</td><td>{status(r,clock)}</td><td>{r.received===undefined?'—':new Date(r.received).toISOString()}</td><td>{r.received!==undefined && <button onClick={()=>void show(r.id)}>View heartbeat</button>}</td></tr>)}</tbody></table>
      <button disabled={page===0} onClick={()=>setPage(v=>v-1)}>Previous</button> <button disabled={(page+1)*50>=selected.length} onClick={()=>setPage(v=>v+1)}>Next</button>
      <p role="status">{detail}</p></>}
  </section>;
}
