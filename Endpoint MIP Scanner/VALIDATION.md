# Validation — suite 1.1.0

Executed on Windows, using a clean temporary directory initially containing only Install-EndpointMIPScanner.ps1.

- Standalone Local stage fetched the suite from GitHub at commit c348483, built the shared lab with an existing .NET 10 x64 SDK and passed the SDK native initialization, synthetic callback, mapped findings, Office input guards and source-integrity self-test.
- Scanner state-format smoke test passed. A subsequent Download stage reconciled the same installed tree successfully.
- Moved PS5.1 incremental test passed for initial/repeated scans, modified/added/deleted files and metadata reuse.
- Script catalog checked 42 unique tracking IDs and file paths; PS5.1 entry point syntax passed.
- The administrative PowerShell installer downloaded the official 7.6.0 x64 ZIP and verified SHA-256. A test exposed a directory lock when validating the extracted executable before renaming the folder. The final installer publishes the folder before launching validation; this path passed.
- PowerShell 7.6.0 parsed all suite scripts and passed the existing portal activity-scope and pilot-plan tests.
- Native dependency installation on a machine without Visual C++ or .NET, Graph app creation/permission changes, app branding in Entra and real SharePoint foundation changes remain tenant/environment tests. No tenant changes were performed for this PR.
- SDK package references remain File SDK 1.18.148 and MSAL 4.92.0. The installed Purview client's version is unaffected by the bootstrap.

The plan continues to distinguish scanner-local tests from authenticated Microsoft 365 acceptance.
