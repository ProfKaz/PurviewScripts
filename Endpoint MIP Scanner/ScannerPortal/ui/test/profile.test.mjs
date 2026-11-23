import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { parseProfilePath, readPublishedProfile } from '../src/profile.ts';

const bytes = Uint8Array.from(readFileSync(new URL('../../config/managed-profile.example.json', import.meta.url)));
const pathFor = (data, id = 'workstations-audit-pilot') =>
  'profiles/' + id + '/1.0.0/' + createHash('sha256').update(data).digest('hex') + '.json';

test('reads an exact, verified revision', async () => {
  const profile = await readPublishedProfile(pathFor(bytes), bytes.buffer);
  assert.equal(profile.version, '1.0.0');
  assert.ok(profile.files['extensions.json'].includes('.docx'));
});

test('rejects external and traversing references', () => {
  assert.throws(() => parseProfilePath('https://example.com/' + pathFor(bytes)));
  assert.throws(() => parseProfilePath(pathFor(bytes).replace('workstations-audit-pilot', '..')));
});

test('rejects changed bytes and mismatched revision identity', async () => {
  const changed = bytes.slice();
  changed[0] = 32;
  await assert.rejects(readPublishedProfile(pathFor(bytes), changed.buffer), /SHA-256/);
  await assert.rejects(readPublishedProfile(pathFor(bytes, 'other-profile'), bytes.buffer), /revision or schema/);
});

test('rejects invalid fields even when their hash matches', async () => {
  const profile = JSON.parse(new TextDecoder().decode(bytes));
  profile.execution.paused = 'false';
  const invalid = new TextEncoder().encode(JSON.stringify(profile));
  await assert.rejects(readPublishedProfile(pathFor(invalid), invalid.buffer), /revision or schema/);
});
