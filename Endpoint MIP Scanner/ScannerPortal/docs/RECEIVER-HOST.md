# Receiver host automation

Run the receiver on a dedicated, always-on Windows administrative host. Stop the interactive pilot watcher before switching. Setup uses elevated x64 PowerShell and requires a machine-wide PowerShell 7.4.6 or later at `%ProgramFiles%\PowerShell\7\pwsh.exe`. Setup installs PnP.PowerShell 3.2.0 for all users. It uses an interactive Graph administrative connection for one-time app registration, consent and the site grant.

Run `deployment/Install-ScannerPortalReceiverTask.ps1` with the tenant ID, dedicated portal site URL, `-GrantReceiverSiteFullControl` and `-AcknowledgePublisherDenied`. The latter acknowledges the verified denial of endpoint access to ScannerPortalAcceptance in this pilot. Full control of the selected portal site enables the receiver's existing ACL inspections. The receiver registration requests the SharePoint Online Sites.Selected application permission. Administrative Graph permissions belong to the setup session. The task authenticates with the dedicated application and a non-exportable machine certificate valid for one year. Plan certificate rotation before expiry.

Setup prints the task name and health file path. A startup trigger and a repeating two-minute trigger invoke a single pass as LOCAL SERVICE. Overlapping starts are ignored. Program Files holds the pinned scripts and configuration. The service has write access to its state folder and read access to its private key. Its first pass reconciles existing batches against the central ledger using a new checkpoint; large backlogs can take more than one interval. Keep one receiver host active for this pilot.

## Acceptance

1. Read `status.json` as an administrator. Verify `identity = S-1-5-19`, the expected client ID, a recent finish time and `outcome = Completed`. A pending batch gives `PendingRetry`. A startup or permissions error can appear in task history or in the status file. Inspect the task's LastTaskResult and last run time if no fresh status is available.
2. Confirm a new batch reaches acceptance and the executive overview with the interactive watcher stopped.
3. At an approved maintenance time, restart the host. Compare the pass start timestamp with the host boot time. Verify that the scheduled task ran without an interactive sign-in, reused its checkpoint, and completed another pass.

To pause reception, disable the named task. Its next activation can resume from the same checkpoint. Disabling the task and revoking the app's site grant are separate operations.
