# Development and validation

Use PowerShell 7.6 or newer for local setup, azd hooks, runbook validation,
and the maintained Automation runbook. Owned scripts in `scripts/` enforce
this minimum before executing their bodies. Shared vendored sources retain
their reviewed immutable revisions; historical validation receipts retain
the versions originally tested.

Run the repository tests from its root in PowerShell 7.6 or newer:

```powershell
$PSVersionTable.PSVersion
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -Force
Import-Module Pester -RequiredVersion 6.2.0 -Force
(Get-Module Pester).Version
Invoke-Pester -Path ./tests -CI
```

CI uses the same exact Pester version and logs both selected versions. The
runbook verifies its own pinned Pester 6.2.0 package before importing it; the
developer test dependency does not change runtime package locks.

Offline tests do not qualify Azure Automation startup, package import,
published-runbook preservation, report delivery, or tenant permissions.
Those remain separate live acceptance gates in issue #24 and the backlog.
