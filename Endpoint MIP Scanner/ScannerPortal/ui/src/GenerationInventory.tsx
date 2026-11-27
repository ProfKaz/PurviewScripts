import * as React from 'react';
import { SPHttpClient } from '@microsoft/sp-http';
import { MessageBar, MessageBarType, Spinner } from '@fluentui/react';
import styles from './ReportView.module.scss';

interface Snapshot {
  registration: string; profile: string; version: string; generation: string;
  observed: number; recovered: number; combined: number; missingDirectories: number;
  coverage: string; closingRun: string | null; latestRun: string;
  matched: number; negative: number; unknown: number;
}
const coverage: Record<string, string> = {
  CheckpointGap: 'Checkpoint gap', Partial: 'Partial', Closed: 'Closed', ClosedWithCoverageErrors: 'Closed with coverage errors'
};

export function GenerationInventory({ client, web, relative }: {client: SPHttpClient; web: string; relative: string}): React.ReactElement {
  const [rows,setRows] = React.useState<Snapshot[]>();
  const [selected,select] = React.useState('');
  const [error,setError] = React.useState('');
  const [revision,reload] = React.useState(0);
  const key = (row:Snapshot):string => row.registration+'/'+row.generation;
  React.useEffect(() => {
    let active = true;
    setError(''); setRows(undefined);
    async function read(): Promise<Snapshot[]> {
      const path = relative.replace(/\/$/,'') + '/ScannerPortalExecutive/generations.json';
      const url = web + '/_api/web/GetFileByServerRelativePath(decodedurl=@path)/$value?@path=' + encodeURIComponent("'" + path.replace(/'/g,"''") + "'");
      const response = await client.get(url, SPHttpClient.configurations.v1, {headers:{'Cache-Control':'no-cache'}});
      if (response.status === 404) return [];
      if (!response.ok) throw new Error();
      const data = await response.json();
      if (data.schema !== 1 || !Array.isArray(data.generations)) throw new Error();
      for (const row of data.generations as Snapshot[]) {
        if (!row || !Object.prototype.hasOwnProperty.call(coverage,row.coverage) ||
          ![row.combined,row.recovered,row.observed,row.matched,row.negative,row.unknown,row.missingDirectories].every(v=>Number.isSafeInteger(v)&&v>=0) ||
          row.combined !== row.recovered + row.observed || row.observed !== row.matched + row.negative + row.unknown) throw new Error();
      }
      return data.generations;
    }
    read().then(value=>{if(active){ select(current => value.some(r=>key(r)===current) ? current : value.length ? key(value[0]) : ''); setRows(value); }}).catch(()=>{if(active)setError('Could not read the generation summary. Check access and publication.');});
    return ()=>{active=false;};
  },[client,web,relative,revision]);
  const row = rows?.find(r=>key(r)===selected) || rows?.[0];
  return <section><h3>Generation inventory</h3>
    <button onClick={()=>reload(revision+1)}>Refresh generations</button>
    {error ? <MessageBar messageBarType={MessageBarType.error}>{error}</MessageBar> : !rows ? <Spinner label="Loading generations"/> :
      !row ? <p>No generation summaries available.</p> : <>
        <p><label>Device registration <select style={{maxWidth:'100%'}} value={row.registration} onChange={e=>{
          const first=rows.find(r=>r.registration===e.target.value);
          if(first) select(key(first));
        }}>
          {Array.from(new Set(rows.map(r=>r.registration))).map(id=><option key={id} value={id}>{id}</option>)}
        </select></label></p>
        <p><label>Published generation <select style={{maxWidth:'100%'}} value={key(row)} onChange={e=>select(e.target.value)}>
          {rows.filter(r=>r.registration===row.registration).map(r=><option key={key(r)} value={key(r)}>{r.generation}</option>)}
        </select></label></p>
        <p>{row.profile} · {row.version} · Coverage: <strong>{coverage[row.coverage]}</strong></p>
        <div className={styles.metrics}>
          <div><strong>{row.combined.toLocaleString('en-US')}</strong>Distinct paths observed</div>
          <div><strong>{row.recovered.toLocaleString('en-US')}</strong>Recovered from interrupted run</div>
          <div><strong>{row.missingDirectories.toLocaleString('en-US')}</strong>Directories in checkpoint gaps</div>
        </div>
        <p>Purview discovery across {row.observed} paths in summarized cycles: {row.matched} matched · {row.negative} evaluated without matches · {row.unknown} unknown or uninspected.</p>
        <p>Latest summarized run: {row.latestRun} · Closing run: {row.closingRun || 'Not observed'}</p>
      </>}
  </section>;
}
