import * as React from 'react';
import { MessageBar, MessageBarType, PrimaryButton, DefaultButton, Spinner } from '@fluentui/react';
import { AgentConfigStore, AgentProfile, LoadedAgent } from './agentConfig';
import styles from './ReportView.module.scss';

function ProfileEditor({ agent, store, saved }: {agent: LoadedAgent; store: AgentConfigStore; saved:(a:LoadedAgent)=>void}): React.ReactElement {
  const p = agent.profile;
  const perf = p.files['performance.json'], inc = p.files['incremental.json'], classifiers = p.files['classifiers.json'];
  const [busy,setBusy] = React.useState(false);
  const [message,setMessage] = React.useState('');
  const [error,setError] = React.useState('');
  const [rules,setRules] = React.useState(classifiers.rules);
  const form = React.useRef<HTMLFormElement>(null);
  const number = (name:string, label:string, value:number, min:number, max:number): React.ReactElement =>
    <label>{label} <input required type="number" step="1" name={name} defaultValue={value} min={min} max={max}/></label>;
  const toggle = (name:string, label:string, value:boolean):React.ReactElement =>
    <label><input type="checkbox" name={name} defaultChecked={value}/> {label}</label>;
  const lines = (name:string, label:string, value:string[], required=false): React.ReactElement =>
    <label>{label} <textarea name={name} defaultValue={value.join('\n')} rows={3} required={required}/></label>;
  async function publish(rescan:boolean): Promise<void> {
    if (!form.current || !form.current.reportValidity()) return;
    setError(''); setMessage('');
    try {
      const data = new FormData(form.current);
      const str = (k:string):string => String(data.get(k) || '').trim();
      const list = (k:string):string[] => str(k).split(/\r?\n/).map(x=>x.trim()).filter(Boolean);
      const draft = JSON.parse(JSON.stringify(p)) as AgentProfile;
      const sitIds = list('purviewSits').map(x=>x.toLowerCase());
      if (sitIds.length > 16 || new Set(sitIds).size !== sitIds.length ||
          sitIds.some(id=>!(/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/).test(id) || /^0{8}-0{4}-0{4}-0{4}-0{12}$/.test(id))) throw new Error('Enter up to 16 distinct Purview SIT GUIDs.');
      if (sitIds.length) draft.purviewSitIds = sitIds; else delete draft.purviewSitIds;
      draft.expiresUtc = str('expires');
      if (!/(Z|\+00:00)$/i.test(draft.expiresUtc) || !(Date.parse(draft.expiresUtc)>Date.now())) throw new Error('Enter a future expiration in UTC.');
      draft.execution = { paused:data.has('paused'), auditContent:data.has('audit'), roots:list('roots'), maxSeconds:Number(str('max')), idleSeconds:Number(str('idle')) };
      draft.files['extensions.json'] = list('extensions');
      draft.files['exclusions.json'] = list('excluded');
      if (!draft.files['extensions.json'].length || draft.files['extensions.json'].some(x=>!/^\.[a-z\d]+$/i.test(x))) throw new Error('Enter file extensions such as .txt, one per line.');
      if (!draft.execution.roots.length || draft.execution.roots.length>32) throw new Error('Enter 1–32 scan roots.');
      for (const value of [...draft.execution.roots,...draft.files['exclusions.json'],str('state')]) {
        if (!/^(?:[a-z]:[\\/]|%[a-z_][a-z0-9_() -]*%(?:[\\/]|$))/i.test(value) || /[:]/.test(value.slice(2))) throw new Error('Enter an absolute local path or a Windows environment variable: '+value);
      }
      if (!rules.length || rules.length>32 || new Set(rules.map(r=>r.id.toLowerCase())).size!==rules.length ||
          rules.some(r=>!/^[a-z][a-z0-9-]{0,63}$/i.test(r.id) || !r.pattern.length || r.pattern.length>1024)) throw new Error('Enter 1–32 unique rule IDs and patterns of 1–1024 characters.');
      draft.files['classifiers.json'] = { maxBytes:Number(str('bytes')),rules };
      draft.files['performance.json'] = {batchSize:Number(str('batch')),pauseMilliseconds:Number(str('pause'))};
      draft.files['incremental.json'] = {enabled:data.has('incremental'),rescanIntervalDays:Number(str('days')),detectModifiedFiles:data.has('modified'),
        detectDeletedFiles:data.has('deleted'),forceFullScan:data.has('force'),maxFileSizeMB:Number(str('size')),stateDirectory:str('state')};
      if (rescan && (draft.execution.paused || !draft.files['incremental.json'].enabled)) throw new Error('Enable scanning and incremental state to request a full rescan.');
      if (!rescan && JSON.stringify(draft.purviewSitIds)===JSON.stringify(p.purviewSitIds) && JSON.stringify(draft.files)===JSON.stringify(p.files) && JSON.stringify(draft.execution.roots)===JSON.stringify(p.execution.roots) &&
        Object.keys(draft.execution).every(key=>key==='roots'||draft.execution[key as keyof typeof p.execution]===p.execution[key as keyof typeof p.execution]) && draft.expiresUtc===p.expiresUtc) {
        setMessage('No configuration changes to publish.'); return;
      }
      if (!window.confirm((rescan?'Publish these settings and start a fresh inventory':'Publish these settings')+' for '+agent.id+' at its next sync?')) return;
      setBusy(true);
      saved(await store.publish(agent,draft,rescan));
    } catch(e) {setError((e as Error).message);}
    finally {setBusy(false);}
  }
  return <form className={styles.agentEditor} ref={form} onSubmit={e=>e.preventDefault()}><fieldset disabled={busy}>
    <legend>{p.profileId} · {p.version}</legend>
    {toggle('paused','Pause this agent',p.execution.paused)}{toggle('audit','Audit content',p.execution.auditContent)}
    {lines('roots','Scan roots (one per line)',p.execution.roots,true)}
    <fieldset><legend>Microsoft Purview discovery</legend>
      {lines('purviewSits','Selected SIT GUIDs (one per line)',p.purviewSitIds || [])}
      <p>Leave empty to disable. A selection checks each inventoried file with the installed Purview client and reads its sensitivity label separately. Start with the pilot controls folder.</p>
      <button type="button" onClick={()=>{const input=form.current?.elements.namedItem('purviewSits') as HTMLTextAreaElement;
        const id='50842eb7-edc8-4019-85dd-5a5c1f2bb085'; if(input && !input.value.toLowerCase().includes(id)) input.value=(input.value.trim()+'\n'+id).trim();}}>Add Credit card number</button>
    </fieldset>
    {lines('extensions','File extensions (one per line)',p.files['extensions.json'],true)}
    {lines('excluded','Excluded paths (one per line)',p.files['exclusions.json'])}
    <fieldset><legend>Sensitive data · local detection rules</legend>
      <p>The Windows agent validates each .NET pattern when it syncs. Local content auditing covers TXT and CSV.</p>
      {rules.map((r,i)=><div key={i}><label>Rule ID <input required value={r.id} onChange={e=>setRules(rules.map((x,j)=>i===j?{...x,id:e.target.value}:x))}/></label>
        <label> .NET regular expression <input required maxLength={1024} value={r.pattern} onChange={e=>setRules(rules.map((x,j)=>i===j?{...x,pattern:e.target.value}:x))}/></label>
        <button type="button" onClick={()=>setRules(rules.filter((_,j)=>j!==i))}>Remove rule</button></div>)}
      <button type="button" disabled={rules.length>=32} onClick={()=>setRules([...rules,{id:'',pattern:''}])}>Add rule</button>
    </fieldset>
    {number('bytes','Content audit limit (bytes)',classifiers.maxBytes,1,4194304)}
    {number('max','Cycle budget (seconds)',p.execution.maxSeconds,1,3600)}
    {number('idle','Interval between cycles (seconds)',p.execution.idleSeconds,30,86400)}
    {number('batch','Batch size',perf.batchSize,1,10000)}
    {number('pause','Pause between batches (ms)',perf.pauseMilliseconds,0,10000)}
    {toggle('incremental','Enable incremental inventory',inc.enabled)}
    {toggle('modified','Detect modified files',inc.detectModifiedFiles)}
    {toggle('deleted','Detect deleted files',inc.detectDeletedFiles)}
    {toggle('force','Force full scans while this profile is active',inc.forceFullScan)}
    {number('days','Rescan interval (days)',inc.rescanIntervalDays,1,36500)}
    {number('size','Maximum file size (MB)',inc.maxFileSizeMB,1,36500)}
    <label>Index directory <input required name="state" defaultValue={inc.stateDirectory} size={60}/></label>
    <label>Expiration (UTC) <input required name="expires" defaultValue={p.expiresUtc} size={32}/></label>
    <div><PrimaryButton text="Publish configuration" onClick={()=>void publish(false)} disabled={busy}/>
    {' '}<DefaultButton text="Request full rescan" onClick={()=>void publish(true)} disabled={busy}/></div>
    {inc.stateDirectory.indexOf('\\rescan-'+p.version.split('.')[2]+'-')>=0 && <DefaultButton text="Check rescan progress" disabled={busy} onClick={async()=>{
      setBusy(true); setError(''); try {setMessage(await store.progress(agent));} catch(e){setError((e as Error).message);} finally{setBusy(false);}
    }}/>}
  </fieldset>{message && <MessageBar>{message}</MessageBar>}{error && <MessageBar messageBarType={MessageBarType.error}>{error}</MessageBar>}</form>;
}
export function AgentSettings({store}: {store:AgentConfigStore}):React.ReactElement {
  const [devices,setDevices]=React.useState<string[]>([]);
  const [id,setId]=React.useState('');
  const [agent,setAgent]=React.useState<LoadedAgent>();
  const [error,setError]=React.useState('');
  const [notice,setNotice]=React.useState('');
  const [reload,setReload]=React.useState(0);
  React.useEffect(()=>{
    let active=true;
    store.devices().then(rows=>{if(active)setDevices(rows);}).catch(e=>{if(active)setError(e.message);});
    return ()=>{active=false;};
  },[store,reload]);
  React.useEffect(()=>{
    let active=true;setAgent(undefined);setNotice('');setError('');
    if(id) store.load(id).then(value=>{if(active)setAgent(value);}).catch(e=>{if(active)setError(e.message);});
    return ()=>{active=false;};
  },[store,id,reload]);
  const selected=React.useRef(id);selected.current=id;
  return <section><h2>Agent configuration</h2><label>Device registration <select value={id} onChange={e=>setId(e.target.value)}>
    <option value="">Select a device</option>{devices.map(d=><option key={d}>{d}</option>)}</select></label>
    {' '}<button type="button" onClick={()=>setReload(x=>x+1)}>Reload</button>
    {error && <MessageBar messageBarType={MessageBarType.error}>{error}</MessageBar>}
    {notice && <MessageBar messageBarType={MessageBarType.success}>{notice}</MessageBar>}
    {id && !agent && !error && <Spinner label="Loading assigned profile…"/>}
    {agent && agent.id===id && <ProfileEditor key={agent.path} agent={agent} store={store} saved={a=>{
      if(selected.current===a.id){setAgent(a);setNotice('Assignment verified. The agent will read revision '+a.profile.version+' at its next sync.');}
    }}/>}
  </section>;
}
