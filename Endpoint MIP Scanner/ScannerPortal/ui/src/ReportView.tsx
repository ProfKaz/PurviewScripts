import * as React from 'react';
import { SearchBox, Dropdown, MessageBar, MessageBarType, Spinner } from '@fluentui/react';
import { Report } from './report';
import styles from './ReportView.module.scss';

const number = new Intl.NumberFormat('es-CO');
const outcomeNames: Record<string, string> = {
  Responded: 'Con respuesta', NoResponse: 'Sin respuesta', Error: 'Error', SkippedOfflineOrReparse: 'Omitido'
};
type SortKey = 'Files' | 'Matches' | 'Name';

export function ReportView({ report, error }: { report?: Report; error?: string }): React.ReactElement {
  const [query, setQuery] = React.useState('');
  const [sort, setSort] = React.useState<SortKey>('Files');
  const [tab, setTab] = React.useState<'overview' | 'types'>('overview');
  if (error) return <MessageBar messageBarType={MessageBarType.error}>{error}</MessageBar>;
  if (!report) return <Spinner label="Cargando reporte…" />;

  const total = report.ByExtension.reduce((sum, row) => sum + row.Files, 0);
  const needle = query.trim().toLocaleLowerCase();
  const rows = report.BySit.filter(row => (row.Name || '').toLocaleLowerCase().includes(needle) || row.SitId.toLowerCase().includes(needle))
    .sort((a, b) => sort === 'Name' ? (a.Name || a.SitId).localeCompare(b.Name || b.SitId) : b[sort] - a[sort] || a.SitId.localeCompare(b.SitId));

  return <section className={styles.report} aria-label="Reporte de descubrimiento">
    <nav className={styles.nav} aria-label="Secciones del reporte">
      <button type="button" aria-pressed={tab === 'overview'} onClick={() => setTab('overview')}>Resumen</button>
      <button type="button" aria-pressed={tab === 'types'} onClick={() => setTab('types')}>Tipos detectados</button>
    </nav>
    <div className={styles.body}>
      <h2>{tab === 'overview' ? 'Reporte de descubrimiento' : 'Tipos de información confidencial'}</h2>
      {tab === 'overview' ? <>
        <div className={styles.metrics}>
          <div><strong>{number.format(total)}</strong>Archivos del lote</div>
          <div><strong>{number.format(report.BySit.length)}</strong>Tipos detectados</div>
          <div><strong>{number.format(report.CoverageErrors)}</strong>Errores de cobertura</div>
        </div>
        <div className={styles.panels}>
          <table><caption>Archivos por resultado</caption><thead><tr><th scope="col">Resultado</th><th scope="col">Archivos</th></tr></thead>
            <tbody>{report.ByOutcome.map(row => <tr key={row.Outcome}><td>{outcomeNames[row.Outcome] || row.Outcome}</td><td>{number.format(row.Files)}</td></tr>)}</tbody>
          </table>
          <table><caption>Archivos por extensión</caption><thead><tr><th scope="col">Extensión</th><th scope="col">Archivos</th></tr></thead>
            <tbody>{report.ByExtension.map(row => <tr key={row.Extension}><td>{row.Extension}</td><td>{number.format(row.Files)}</td></tr>)}</tbody>
          </table>
        </div>
      </> : <>
        <div className={styles.filters}>
          <SearchBox ariaLabel="Buscar por nombre o identificador" placeholder="Buscar un tipo" onChange={(_, value) => setQuery(value || '')} />
          <Dropdown ariaLabel="Ordenar tipos" selectedKey={sort} options={[{ key: 'Files', text: 'Archivos' }, { key: 'Matches', text: 'Coincidencias' }, { key: 'Name', text: 'Nombre' }]}
            onChange={(_, option) => { if (option) setSort(option.key as SortKey); }} />
        </div>
        <p role="status">{number.format(rows.length)} tipos. Un archivo puede aparecer en varios tipos.</p>
        {rows.length > 0 && <table><caption>Tipos detectados en el lote</caption><thead><tr><th scope="col">Tipo</th><th scope="col">Archivos</th><th scope="col">Coincidencias</th></tr></thead>
          <tbody>{rows.map(row => <tr key={row.SitId}><td>{row.Name || row.SitId}</td><td>{number.format(row.Files)}</td><td>{number.format(row.Matches)}</td></tr>)}</tbody>
        </table>}
      </>}
    </div>
  </section>;
}
