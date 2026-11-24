import * as React from 'react';
import { MessageBar, Spinner } from '@fluentui/react';
import styles from './ReportView.module.scss';

interface Group {
  device: string; account: string | null; runs: number; observations: number; findings: number; coverageErrors: number;
  extensions: Record<string, number>; detections: Record<string, number>;
}
export interface Snapshot { schema: number; generatedUtc: string; excluded: number; pending: number; groups: Group[] }

function Distribution({ title, unit, values }: {title: string; unit: string; values: Record<string, number>}): React.ReactElement {
  const [filter, setFilter] = React.useState('');
  const rows = Object.keys(values).filter(k => k.toLowerCase().includes(filter.toLowerCase())).sort((a,b) => values[b]-values[a] || a.localeCompare(b));
  const max = Math.max(1, ...rows.map(k => values[k]));
  return <section className={styles.distribution}><h3>{title}</h3>
    <label>Filter {title.toLowerCase()} <input type="search" value={filter} onChange={e => setFilter(e.target.value)} /></label>
    <table><thead><tr><th scope="col">Category</th><th scope="col">{unit}</th></tr></thead>
      <tbody>{rows.map(k => <tr key={k}><th scope="row">{k}</th><td><meter aria-label={k} min={0} max={max} value={values[k]} /> {values[k].toLocaleString('en-US')}</td></tr>)}</tbody></table>
    {!rows.length && <p>No matching categories.</p>}</section>;
}

export function Overview({load}: {load: () => Promise<Snapshot>}): React.ReactElement {
  const [data,setData] = React.useState<Snapshot>();
  const [error,setError] = React.useState('');
  const [device,setDevice] = React.useState('');
  const [user,setUser] = React.useState('');
  React.useEffect(() => {
    let active = true;
    load().then(result => { if (active) setData(result); }).catch((e: Error) => { if (active) setError(e.message); });
    return () => { active = false; };
  }, [load]);
  if (error) return <MessageBar>{error}</MessageBar>;
  if (!data) return <Spinner label="Loading governance overview…" />;
  const account = (g: Group): string => g.account || 'Unattributed';
  const devices = Array.from(new Set(data.groups.map(g => g.device))).sort();
  const groups = data.groups.filter(g => !device || g.device === device);
  const accounts = Array.from(new Set(groups.map(account))).sort();
  const rows = groups.filter(g => !user || account(g) === user);
  const totals = (key: 'observations'|'findings'|'runs'|'coverageErrors'): number => rows.reduce((n,g)=> n+g[key],0);
  const sum = (key: 'extensions'|'detections'): Record<string,number> => {
    const out: Record<string,number> = Object.create(null);
    for (const g of rows) for (const k of Object.keys(g[key])) out[k] = (out[k] || 0) + g[key][k];
    return out;
  };
  const metrics: [string,number][] = [['Reporting identities',new Set(rows.map(g=>g.device)).size],['File observations',totals('observations')],
    ['Observations with findings',totals('findings')],['Coverage errors',totals('coverageErrors')]];
  return <section className={styles.body}><h2>Data governance overview</h2>
    <p>Accepted reports through {new Date(data.generatedUtc).toLocaleString('en-US', {timeZone:'UTC'})} UTC · {totals('runs')} included in this view</p>
    <div className={styles.filters}><label>Reporting device <select value={device} onChange={e=>{setDevice(e.target.value);setUser('');}}>
      <option value="">All devices</option>{devices.map(d=><option key={d}>{d}</option>)}</select></label>
      <label>Account <select value={user} onChange={e=>setUser(e.target.value)}><option value="">All accounts</option>
        {accounts.map(a=><option key={a}>{a}</option>)}</select></label></div>
    <div className={styles.metrics}>{metrics.map(([label,value])=><div key={label}><strong>{value.toLocaleString('en-US')}</strong>{label}</div>)}</div>
    <p>Repeat scans count as additional observations. Devices are identified by their reporting IDs.</p>
    <div className={styles.panels}><Distribution title="File extensions" unit="Observations" values={sum('extensions')} />
    <Distribution title="Sensitive data detections" unit="Matches" values={sum('detections')} /></div>
    <small>{data.excluded} excluded batches · {data.pending} accepted batches awaiting a report</small></section>;
}
