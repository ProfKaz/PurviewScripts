export interface PublishedProfile {
  profileId: string;
  version: string;
  expiresUtc: string;
  execution: { paused: boolean; auditContent: boolean; roots: string[]; maxSeconds: number; idleSeconds: number };
  files: { 'extensions.json': string[]; 'exclusions.json': string[] };
}

export function parseProfilePath(path: string): { id: string; version: string; sha256: string } {
  const match = /^profiles\/([a-z0-9][a-z0-9-]{0,63})\/(\d+\.\d+\.\d+)\/([a-f\d]{64})\.json$/i.exec(path);
  if (!match) throw new Error('Set a published revision path relative to ScannerPortalConfig.');
  return { id: match[1], version: match[2], sha256: match[3].toUpperCase() };
}

export async function readPublishedProfile(path: string, bytes: ArrayBuffer): Promise<PublishedProfile> {
  const reference = parseProfilePath(path);
  if (bytes.byteLength > 1024 * 1024) throw new Error('The published profile exceeds 1 MiB.');
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  const sha256 = Array.from(new Uint8Array(digest), byte => ('0' + byte.toString(16)).slice(-2)).join('').toUpperCase();
  if (sha256 !== reference.sha256) throw new Error('The published profile failed SHA-256 verification.');

  const profile = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)) as PublishedProfile & { schemaVersion: number };
  const execution = profile?.execution;
  const strings = (value: unknown): boolean =>
    Array.isArray(value) && value.every(entry => typeof entry === 'string' && entry.trim().length > 0);

  if (profile?.schemaVersion !== 1 || profile.profileId !== reference.id || profile.version !== reference.version ||
      typeof profile.expiresUtc !== 'string' || !Number.isFinite(Date.parse(profile.expiresUtc)) ||
      typeof execution?.paused !== 'boolean' || typeof execution.auditContent !== 'boolean' ||
      !Number.isSafeInteger(execution.maxSeconds) || !Number.isSafeInteger(execution.idleSeconds) ||
      !strings(execution.roots) || !strings(profile.files?.['extensions.json']) || !strings(profile.files?.['exclusions.json'])) {
    throw new Error('The published profile does not match the expected revision or schema.');
  }
  return profile;
}
