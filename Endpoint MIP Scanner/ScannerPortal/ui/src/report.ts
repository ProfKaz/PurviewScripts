export interface Report {
  SchemaVersion: number;
  AcceptanceKey: string;
  ManifestSha256: string;
  BatchId: string;
  CoverageErrors: number;
  ManagedInventory?: {
    AuditEnabled: boolean; AnalyzedFiles: number; ReusedFiles: number; FilesWithMatches: number;
    AuditSkippedFiles: number; AuditErrors: number; GenerationComplete: boolean;
    ByLocalRule: { RuleId: string; Files: number; Matches: number }[];
  };
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
  const inventory = report.ManagedInventory;
  if (inventory !== undefined && (!inventory || typeof inventory.AuditEnabled !== 'boolean' ||
      typeof inventory.GenerationComplete !== 'boolean' ||
      ![inventory.AnalyzedFiles, inventory.ReusedFiles, inventory.FilesWithMatches,
        inventory.AuditSkippedFiles, inventory.AuditErrors].every(count) ||
      inventory.FilesWithMatches > inventory.AnalyzedFiles ||
      inventory.AnalyzedFiles + inventory.ReusedFiles + inventory.AuditSkippedFiles + inventory.AuditErrors > sum(report.ByExtension) ||
      !Array.isArray(inventory.ByLocalRule) ||
      !inventory.ByLocalRule.every(row => row && text(row.RuleId) && count(row.Files) && count(row.Matches)) ||
      (!inventory.AuditEnabled && (inventory.AnalyzedFiles + inventory.ReusedFiles + inventory.FilesWithMatches +
        inventory.AuditSkippedFiles + inventory.AuditErrors + inventory.ByLocalRule.length > 0)) ||
      report.BySit.length !== 0)) {
    throw new Error('Invalid managed inventory report.');
  }
  return report;
}

export function parseAcceptanceIds(defaultId: string, history: string): number[] {
  const input = [defaultId, ...(history.trim() ? history.split(',') : [])];
  if (input.length > 10) throw new Error('Configure at most ten acceptance items, including the default.');
  const ids: number[] = [];
  for (const entry of input) {
    const value = entry.trim();
    const id = Number(value);
    if (!/^\d+$/.test(value) || !Number.isInteger(id) || id < 1 || id > 2147483647) {
      throw new Error('Acceptance item IDs must be positive integers.');
    }
    if (ids.indexOf(id) === -1) ids.push(id);
  }
  return ids;
}
