import * as React from 'react';
import { SearchBox, Dropdown, MessageBar, MessageBarType, Spinner } from '@fluentui/react';
import { Report } from './report';
import styles from './ReportView.module.scss';

const number = new Intl.NumberFormat('en-US');
const outcomeNames: Record<string, string> = {
  Responded: 'Responded', NoResponse: 'No response', Error: 'Error', SkippedOfflineOrReparse: 'Skipped'
};
type SortKey = 'Files' | 'Matches' | 'Name';

export function ReportView({ report, error }: { report?: Report; error?: string }): React.ReactElement {
  const [query, setQuery] = React.useState('');
  const [sort, setSort] = React.useState<SortKey>('Files');
  const [tab, setTab] = React.useState<'overview' | 'types'>('overview');
  if (error) return <MessageBar messageBarType={MessageBarType.error}>{error}</MessageBar>;
  if (!report) return <Spinner label="Loading report…" />;

  const inventory = report.ManagedInventory;
  const total = report.ByExtension.reduce((sum, row) => sum + row.Files, 0);
  const needle = query.trim().toLocaleLowerCase();
  const rows = report.BySit.filter(row => (row.Name || '').toLocaleLowerCase().includes(needle) || row.SitId.toLowerCase().includes(needle))
    .sort((a, b) => sort === 'Name' ? (a.Name || a.SitId).localeCompare(b.Name || b.SitId) : b[sort] - a[sort] || a.SitId.localeCompare(b.SitId));

  if (inventory) return <section className={styles.report} aria-label="Managed inventory report">
    <div className={styles.body}>
      <h2>Managed inventory</h2>
      <p>{inventory.GenerationComplete ? 'Inventory generation complete' : 'Partial inventory generation'}</p>
      <div className={styles.metrics}>
        <div><strong>{number.format(total)}</strong>Files inventoried in this run</div>
        <div><strong>{number.format(inventory.AnalyzedFiles)}</strong>Files analyzed in this run</div>
        <div><strong>{number.format(inventory.FilesWithMatches)}</strong>Files with local rule matches</div>
        <div><strong>{number.format(report.CoverageErrors)}</strong>Inventory errors</div>
      </div>
      <p>{inventory.AuditEnabled
        ? 'Local content rules (TXT and CSV). Reused: ' + number.format(inventory.ReusedFiles) +
          '. Skipped: ' + number.format(inventory.AuditSkippedFiles) + '. Audit errors: ' + number.format(inventory.AuditErrors) + '.'
        : 'Content audit disabled.'}</p>
      <div className={styles.panels}>
        <table><caption>Files by extension</caption><thead><tr><th scope="col">Extension</th><th scope="col">Files</th></tr></thead>
          <tbody>{report.ByExtension.map(row => <tr key={row.Extension}><td>{row.Extension}</td><td>{number.format(row.Files)}</td></tr>)}</tbody>
        </table>
        {inventory.ByLocalRule.length > 0 && <table><caption>Local rule matches in this run</caption>
          <thead><tr><th scope="col">Rule</th><th scope="col">Files</th><th scope="col">Matches</th></tr></thead>
          <tbody>{inventory.ByLocalRule.map(row => <tr key={row.RuleId}><td>{row.RuleId}</td><td>{number.format(row.Files)}</td><td>{number.format(row.Matches)}</td></tr>)}</tbody>
        </table>}
      </div>
    </div>
  </section>;

  return <section className={styles.report} aria-label="Discovery report">
    <nav className={styles.nav} aria-label="Report sections">
      <button type="button" aria-pressed={tab === 'overview'} onClick={() => setTab('overview')}>Overview</button>
      <button type="button" aria-pressed={tab === 'types'} onClick={() => setTab('types')}>Detected types</button>
    </nav>
    <div className={styles.body}>
      <h2>{tab === 'overview' ? 'Discovery report' : 'Sensitive information types'}</h2>
      {tab === 'overview' ? <>
        <div className={styles.metrics}>
          <div><strong>{number.format(total)}</strong>Files in batch</div>
          <div><strong>{number.format(report.BySit.length)}</strong>Detected types</div>
          <div><strong>{number.format(report.CoverageErrors)}</strong>Coverage errors</div>
        </div>
        <div className={styles.panels}>
          <table><caption>Files by outcome</caption><thead><tr><th scope="col">Outcome</th><th scope="col">Files</th></tr></thead>
            <tbody>{report.ByOutcome.map(row => <tr key={row.Outcome}><td>{outcomeNames[row.Outcome] || row.Outcome}</td><td>{number.format(row.Files)}</td></tr>)}</tbody>
          </table>
          <table><caption>Files by extension</caption><thead><tr><th scope="col">Extension</th><th scope="col">Files</th></tr></thead>
            <tbody>{report.ByExtension.map(row => <tr key={row.Extension}><td>{row.Extension}</td><td>{number.format(row.Files)}</td></tr>)}</tbody>
          </table>
        </div>
      </> : <>
        <div className={styles.filters}>
          <SearchBox ariaLabel="Search by name or ID" placeholder="Search types" onChange={(_, value) => setQuery(value || '')} />
          <Dropdown ariaLabel="Sort types" selectedKey={sort} options={[{ key: 'Files', text: 'Files' }, { key: 'Matches', text: 'Matches' }, { key: 'Name', text: 'Name' }]}
            onChange={(_, option) => { if (option) setSort(option.key as SortKey); }} />
        </div>
        <p role="status">{number.format(rows.length)} types. A file can appear under multiple types.</p>
        {rows.length > 0 && <table><caption>Sensitive information types detected in this batch</caption><thead><tr><th scope="col">Type</th><th scope="col">Files</th><th scope="col">Matches</th></tr></thead>
          <tbody>{rows.map(row => <tr key={row.SitId}><td>{row.Name || row.SitId}</td><td>{number.format(row.Files)}</td><td>{number.format(row.Matches)}</td></tr>)}</tbody>
        </table>}
      </>}
    </div>
  </section>;
}
