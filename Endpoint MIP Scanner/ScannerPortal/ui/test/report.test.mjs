import assert from 'node:assert/strict';
import test from 'node:test';
import { parseReport } from '../src/report.ts';

const report = {
  SchemaVersion: 1, AcceptanceKey: 'key', ManifestSha256: 'hash', BatchId: 'batch',
  CoverageErrors: 13,
  ByExtension: [312, 130, 325, 50, 1426, 50].map((Files, i) => ({ Files, Extension: ['.csv','.docx','.pdf','.pptx','.txt','.xlsx'][i] })),
  ByOutcome: [{ Outcome: 'Responded', Files: 1814 }, { Outcome: 'NoResponse', Files: 479 }],
  BySit: [{ SitId: 'type', Name: null, Files: 5, Matches: 23 }]
};
const item = { Title: 'key', ManifestSha256: 'hash', BatchId: 'batch', PortalReportJson: JSON.stringify(report) };

test('reads totals and accepts unnamed detection types', () => {
  assert.equal(parseReport(item).ByExtension.reduce((sum, row) => sum + row.Files, 0), 2293);
});
test('rejects a report bound to a different acceptance', () => {
  assert.throws(() => parseReport({ ...item, Title: 'other' }), /aceptación/);
});
test('rejects inconsistent aggregate totals', () => {
  const inconsistent = { ...report, ByOutcome: [{ Outcome: 'Responded', Files: 1 }] };
  assert.throws(() => parseReport({ ...item, PortalReportJson: JSON.stringify(inconsistent) }), /totales/);
});
