export interface Report {
  SchemaVersion: number;
  AcceptanceKey: string;
  ManifestSha256: string;
  BatchId: string;
  CoverageErrors: number;
  ByExtension: { Extension: string; Files: number }[];
  ByOutcome: { Outcome: string; Files: number }[];
  BySit: { SitId: string; Name: string; Files: number; Matches: number }[];
}

const count = (value: unknown): value is number => Number.isSafeInteger(value) && Number(value) >= 0;
const text = (value: unknown): value is string => typeof value === 'string' && value.length > 0;

export function parseReport(item: { Title: string; BatchId: string; ManifestSha256: string; PortalReportJson: string }): Report {
  const report = JSON.parse(item.PortalReportJson) as Report;
  if (!report || report.SchemaVersion !== 1 || !text(report.AcceptanceKey) ||
      report.AcceptanceKey !== item.Title || !text(report.BatchId) || report.BatchId !== item.BatchId ||
      !text(report.ManifestSha256) || report.ManifestSha256 !== item.ManifestSha256 ||
      !count(report.CoverageErrors) ||
      !Array.isArray(report.ByExtension) || !report.ByExtension.every(row => row && text(row.Extension) && count(row.Files)) ||
      !Array.isArray(report.ByOutcome) || !report.ByOutcome.every(row => row && text(row.Outcome) && count(row.Files)) ||
      !Array.isArray(report.BySit) || !report.BySit.every(row => row && text(row.SitId) && count(row.Files) && count(row.Matches) && (row.Name == null || typeof row.Name === 'string'))) {
    throw new Error('The stored report does not match its acceptance record or has an invalid format.');
  }
  const sum = (rows: { Files: number }[]): number => rows.reduce((total, row) => total + row.Files, 0);
  if (sum(report.ByExtension) !== sum(report.ByOutcome)) {
    throw new Error('Totals by extension and outcome do not match.');
  }
  return report;
}
