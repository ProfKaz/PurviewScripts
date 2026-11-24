import * as React from 'react';
import { MessageBar, MessageBarType, Spinner } from '@fluentui/react';
import { Report } from './report';
import styles from './ReportView.module.scss';

export interface Cycle { id: number; device: string; report: Report }

export function ConsolidatedView({ load }: { load: () => Promise<Cycle[]> }): React.ReactElement {
  const [cycles, setCycles] = React.useState<Cycle[]>();
  const [selected, setSelected] = React.useState<number[]>([]);
  const [error, setError] = React.useState('');
  React.useEffect(() => {
    let active = true;
    load().then(rows => { if (active) setCycles(rows); })
      .catch(() => { if (active) setError('Could not read or validate the accepted inventory reports.'); });
    return () => { active = false; };
  }, [load]);
  if (error) return <MessageBar messageBarType={MessageBarType.error}>{error}</MessageBar>;
  if (!cycles) return <Spinner label="Loading accepted inventory reports…" />;
  const chosen = cycles.filter(c => selected.indexOf(c.id) >= 0);
  const extensions = new Map<string, number>();
  const rules = new Map<string, { files: number; matches: number }>();
  let files = 0, analyzed = 0, matched = 0, skipped = 0, reused = 0, errors = 0, coverage = 0;
  for (const cycle of chosen) {
    const inventory = cycle.report.ManagedInventory!;
    for (const row of cycle.report.ByExtension) {
      files += row.Files;
      extensions.set(row.Extension, (extensions.get(row.Extension) || 0) + row.Files);
    }
    for (const row of inventory.ByLocalRule) {
      const totals = rules.get(row.RuleId) || { files: 0, matches: 0 };
      rules.set(row.RuleId, { files: totals.files + row.Files, matches: totals.matches + row.Matches });
    }
    analyzed += inventory.AnalyzedFiles;
    matched += inventory.FilesWithMatches;
    skipped += inventory.AuditSkippedFiles;
    reused += inventory.ReusedFiles;
    errors += inventory.AuditErrors;
    coverage += cycle.report.CoverageErrors;
  }
  const metrics: [string, number][] = [
    ['File observations', files], ['Analyzed', analyzed], ['With matches', matched], ['Reused', reused],
    ['Skipped', skipped], ['Audit errors', errors], ['Coverage errors', coverage]
  ];
  return <section className={styles.body}>
    <h2>Consolidated inventory</h2>
    <p>Select cycles from one device. Totals count observations across the selected runs. A file scanned twice contributes twice.</p>
    <fieldset><legend>Managed cycles among the 50 latest acceptance records</legend>
      {cycles.length === 0 && <p>No managed cycles in this range.</p>}
      {cycles.map(c => <div key={c.id}><label><input type="checkbox" checked={selected.indexOf(c.id) >= 0}
        disabled={chosen.length > 0 && chosen[0].device !== c.device}
        onChange={e => setSelected(e.target.checked ? [...selected, c.id] : selected.filter(id => id !== c.id))} />
        {' Acceptance #' + c.id + ' · Device ' + c.device + (c.report.ManagedInventory!.GenerationComplete ? ' · Closing cycle' : '')}
      </label></div>)}
    </fieldset>
    {chosen.length > 0 && <><div className={styles.metrics}>
      {metrics.map(([label, value]) =>
        <div key={label}><strong>{value.toLocaleString('en-US')}</strong>{label}</div>)}
    </div><div className={styles.panels}>
      <table><caption>Observations by extension</caption><thead><tr><th>Extension</th><th>Observations</th></tr></thead>
      <tbody>{Array.from(extensions.keys()).sort().map(ext => <tr key={ext}><td>{ext}</td><td>{extensions.get(ext)}</td></tr>)}</tbody></table>
      <table><caption>Local rule matches</caption><thead><tr><th>Rule</th><th>File observations</th><th>Matches</th></tr></thead>
      <tbody>{Array.from(rules.keys()).sort().map(id => <tr key={id}><td>{id}</td><td>{rules.get(id)!.files}</td><td>{rules.get(id)!.matches}</td></tr>)}</tbody></table>
    </div></>}
  </section>;
}
