import * as React from 'react';
import { MessageBar, MessageBarType } from '@fluentui/react';
import { SPHttpClient } from '@microsoft/sp-http';

export interface AuditRow {
  Id: number;
  BatchId: string;
  ReportingDeviceId: string;
  Created: string;
  RunComputer?: string;
  RunAccount?: string;
  RunAccountSid?: string;
}
const columns = { RunComputer: 'Computer name', RunAccount: 'Windows account', RunAccountSid: 'Windows SID' };
type Column = keyof typeof columns;

export function RunAudit({client, web, ledger, openBatch}: {client:SPHttpClient; web:string; ledger:string; openBatch:(id:number)=>void}):React.ReactElement {
  const [field,setField] = React.useState<Column>('RunComputer');
  const [term,setTerm] = React.useState('');
  const [query,setQuery] = React.useState({field, term:'', before:0});
  const [rows,setRows] = React.useState<AuditRow[]>([]);
  const [busy,setBusy] = React.useState(true);
  const [more,setMore] = React.useState(false);
  const [error,setError] = React.useState('');
  React.useEffect(()=>{
    let active = true;
    async function read():Promise<void> {
      setBusy(true); setError(''); setMore(false);
      if (!query.before) setRows([]);
      if (!/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(ledger)) throw new Error('Configure the acceptance list GUID.');
      const filters:string[] = [];
      if (query.term) filters.push(query.field+" eq '"+query.term.replace(/'/g,"''")+"'");
      if (query.before) filters.push('Id lt '+query.before);
      const url = web+"/_api/web/lists(guid'"+ledger+"')/items?$select=Id,BatchId,ReportingDeviceId,Created,RunComputer,RunAccount,RunAccountSid"+
        '&$orderby=Id desc&$top=51'+(filters.length?'&$filter='+encodeURIComponent(filters.join(' and ')):'');
      const response=await client.get(url,SPHttpClient.configurations.v1,{headers:{'Cache-Control':'no-cache'}});
      if (!response.ok) throw new Error('Cannot read the run audit (HTTP '+response.status+'). Check access and the audit column installation.');
      const data=await response.json() as {value:AuditRow[]; '@odata.nextLink'?:string; 'odata.nextLink'?:string};
      if (active) {
        const page=data.value.slice(0,50);
        setRows(previous=>query.before?previous.concat(page):page);
        setMore(page.length>0 && (data.value.length>50 || !!data['@odata.nextLink'] || !!data['odata.nextLink']));
      }
    }
    read().catch(e=>{if(active)setError(e.message);}).then(()=>{if(active)setBusy(false);});
    return ()=>{active=false;};
  },[client,web,ledger,query]);
  return <section><h2>Run audit</h2>
    <p>Each row is an accepted batch. The Windows account and computer are reported by the scanning endpoint. The account identifies the scan session.</p>
    <form onSubmit={e=>{e.preventDefault();setQuery({field,term:term.trim(),before:0});}}>
      <label>Search by <select value={field} onChange={e=>setField(e.target.value as Column)}>
        {(Object.keys(columns) as Column[]).map(k=><option key={k} value={k}>{columns[k]}</option>)}</select></label>
      {' '}<label>Exact value <input value={term} maxLength={255} onChange={e=>setTerm(e.target.value)}/></label>
      {' '}<button type="submit">Search</button>
      {' '}<button type="button" onClick={()=>{setTerm('');setQuery({field,term:'',before:0});}}>Show latest</button>
    </form>
    {error && <MessageBar messageBarType={MessageBarType.error}>{error}</MessageBar>}
    <div aria-live="polite">{busy?'Loading runs…':!error&&!rows.length?'No matching runs.':''}</div>
    {rows.length>0 && <div style={{overflowX:'auto'}}><table><thead><tr>
      {['Acceptance','Accepted (UTC)','Computer','Windows account','SID','Registration','Run / batch ID'].map(h=><th scope="col" key={h}>{h}</th>)}
    </tr></thead><tbody>{rows.map(r=><tr key={r.Id}><td><button type="button" aria-label={'Open acceptance '+r.Id} onClick={()=>openBatch(r.Id)}>{r.Id}</button></td><td>{new Date(r.Created).toISOString()}</td>
      <td>{r.RunComputer || 'Unknown'}</td><td>{r.RunAccount || 'Unknown'}</td><td>{r.RunAccountSid || 'Unknown'}</td>
      <td>{r.ReportingDeviceId}</td><td>{r.BatchId}</td></tr>)}</tbody></table></div>}
    {more && <button type="button" disabled={busy} onClick={()=>setQuery({...query,before:rows[rows.length-1].Id})}>Load older runs</button>}
  </section>;
}
