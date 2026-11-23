import * as React from 'react';
import { MessageBar, MessageBarType, Spinner, Text } from '@fluentui/react';
import { PublishedProfile, parseProfilePath, readPublishedProfile } from './profile';

export function ConfigurationView({ path, load }: { path: string; load: (path: string) => Promise<ArrayBuffer> }): React.ReactElement {
  const [profile, setProfile] = React.useState<PublishedProfile>();
  const [error, setError] = React.useState<string>();
  React.useEffect(() => {
    let active = true;
    void (async () => {
      try {
        parseProfilePath(path);
        const result = await readPublishedProfile(path, await load(path));
        if (active) setProfile(result);
      } catch (failure) {
        if (active) setError(failure instanceof Error ? failure.message : 'Could not load the published profile.');
      }
    })();
    return () => { active = false; };
  }, [path, load]);

  if (error) return <MessageBar messageBarType={MessageBarType.error}>{error}</MessageBar>;
  if (!profile) return <Spinner label="Verifying the published profile…" />;

  const list = (values: string[]): React.ReactNode => values.length
    ? <ul>{values.map((value, index) => <li key={index}>{value}</li>)}</ul>
    : 'None';

  return <section aria-label="Published scanner configuration">
    <Text as="h2" variant="xLarge">Published profile</Text>
    <p>{profile.profileId} · {profile.version}</p>
    <MessageBar messageBarType={MessageBarType.success}>SHA-256 verified</MessageBar>
    <dl>
      <dt>Execution</dt><dd>{profile.execution.paused ? 'Paused' : 'Enabled in profile'}</dd>
      <dt>Assignment</dt><dd>Not evaluated in this preview</dd>
      <dt>Content audit</dt><dd>{profile.execution.auditContent ? 'Enabled' : 'Disabled'}</dd>
      <dt>Expiration</dt><dd>{new Date(profile.expiresUtc).toISOString()}</dd>
      <dt>Run limit</dt><dd>{profile.execution.maxSeconds} seconds</dd>
      <dt>Idle interval</dt><dd>{profile.execution.idleSeconds} seconds</dd>
      <dt>Scan roots</dt><dd>{list(profile.execution.roots)}</dd>
      <dt>File extensions</dt><dd>{list(profile.files['extensions.json'])}</dd>
      <dt>Excluded paths</dt><dd>{list(profile.files['exclusions.json'])}</dd>
      <dt>SHA-256</dt><dd style={{ overflowWrap: 'anywhere' }}>{parseProfilePath(path).sha256}</dd>
    </dl>
  </section>;
}
