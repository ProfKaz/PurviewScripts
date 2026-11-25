import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import ts from 'typescript';
import * as profileFunctions from '../src/profile.ts';

// Use the real store with an in-memory SharePoint transport.
const source = readFileSync(new URL('../src/agentConfig.ts', import.meta.url), 'utf8');
const exports = {};
new Function('require', 'exports', ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }
}).outputText)(name => name === './profile' ? profileFunctions : {SPHttpClient:{configurations:{v1:{}}}}, exports);
const {AgentConfigStore} = exports;
const device = '42af6b5a-7e31-4df5-b9d7-8f4cb4c0e9e4';
const json = readFileSync(new URL('../../config/managed-profile.example.json', import.meta.url),'utf8');
const digest = createHash('sha256').update(json).digest('hex').toUpperCase();
const root = '/sites/pilot/ScannerPortalConfig/';
const original = 'profiles/workstations-audit-pilot/1.0.0/'+digest+'.json';
function fixture() {
  const assigned = root+'assignments/'+device+'.json';
  const files = new Map([[root+original,json],[assigned,JSON.stringify({registrationId:device,profilePath:original,sha256:digest,schemaVersion:1})]]);
  let revision = 1;
  const extract = (url,key) => new URL(url).searchParams.get(key)?.slice(1,-1);
  const transport = {
    async get(url) {
      if (!url.includes('/$value?')) return Response.json({ETag:'"'+revision+'"'});
      const bytes = files.get(extract(url,'@p'));
      return new Response(bytes,{status:bytes===undefined?404:200,headers:{ETag:'"'+revision+'"'}});
    },
    async post(url,config,opts) {
      const path = extract(url,'@p');
      if (url.includes('/Files/add(')) {
        const file = path+'/'+extract(url,'@name');
        if(files.has(file)) return new Response(null,{status:409});
        files.set(file,opts.body);
      } else if (url.includes('/$value?')) {
        assert.equal(path,assigned);
        if (opts.headers['IF-MATCH']!=='"'+revision+'"') return new Response(null,{status:412});
        files.set(path,opts.body); revision++;
      }
      return new Response(null,{status:200});
    }
  };
  return {store:new AgentConfigStore(transport,'https://example.test/sites/pilot','/sites/pilot',''), files};
}
test('publishes a verified immutable revision and a clean rescan index for the assigned registration', async()=>{
  const {store,files}=fixture();
  const old=await store.load(device);
  const draft=structuredClone(old.profile);
  draft.files['extensions.json'].push('.log');
  const saved=await store.publish(old,draft,true);
  assert.notEqual(saved.path,old.path);
  assert.equal(files.get(root+original),json);
  assert.equal(saved.profile.files['extensions.json'].at(-1),'.log');
  assert.match(saved.profile.files['incremental.json'].stateDirectory,/\\rescan-\d+-[a-f0-9]{32}$/);
  assert.deepEqual(saved.profile.files['classifiers.json'],old.profile.files['classifiers.json']);
  await assert.rejects(store.publish(old,draft,false),/assignment changed/);
  assert.equal((await store.load(device)).path,saved.path);
});
test('ordinary edits retain the index directory and paused rescans leave the assignment intact',async()=>{
  const {store}=fixture();
  const old=await store.load(device);
  const draft=structuredClone(old.profile);
  draft.execution.paused=true;
  await assert.rejects(store.publish(old,draft,true),/Enable scanning/);
  assert.equal((await store.load(device)).path,old.path);
  const saved=await store.publish(old,draft,false);
  assert.equal(saved.profile.files['incremental.json'].stateDirectory,old.profile.files['incremental.json'].stateDirectory);
  assert.equal(saved.profile.execution.paused,true);
});
test('reports closure from accepted bytes even when acceptance order differs from scan order',async()=>{
  const files = new Map();
  const rows = [];
  const sha = text => createHash('sha256').update(text).digest('hex').toUpperCase();
  const generation = '11111111111111111111111111111111';
  for (const [id,hour,closed] of [[204,12,true],[205,11,false]]) {
    const run = String(id).padStart(32,'0');
    const folder = 'devices/'+device+'/batches/'+run;
    const summary = JSON.stringify({profileSha256:digest,summary:{runId:run,generation,
      startedUtc:'2026-11-25T'+hour+':00:00Z',generationComplete:closed,generationHasErrors:true}});
    const manifest = JSON.stringify({files:[{name:'summary.json',sha256:sha(summary)}]});
    files.set(folder+'/manifest.json',manifest);
    files.set(folder+'/summary.json',summary);
    rows.push({Id:id,BatchId:run,SourceRelativePath:folder,PortalReportJson:'{}',ManifestSha256:sha(manifest)});
  }
  const transport = {async get(url) {
    if(url.includes('/items?')) return Response.json({value:rows});
    const path = new URL(url).searchParams.get('@p').slice(1,-1).split('/ScannerPortalLanding/')[1];
    return new Response(files.get(path));
  }};
  const store = new AgentConfigStore(transport,'https://example.test/sites/pilot','/sites/pilot',device);
  const agent = {id:device,path:original,profile:{version:'1.0.1795600800000'}};
  assert.match(await store.progress(agent),/Completed with errors.*205, 204/);
  files.set(rows[0].SourceRelativePath+'/summary.json','{}');
  await assert.rejects(store.progress(agent),/failed verification/);
});
