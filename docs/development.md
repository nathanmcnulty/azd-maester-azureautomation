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

## Canonical target guards

The deployment hooks vendor `maester-azd-hooks` 1.0.0 (pilot) from the reviewed
Reference #111 candidate `fd26f7351f36c569067ae37edcb35d6b6cc40f29`.
`azd-components.lock.json` records the exact source revision and file hashes;
there is no runtime dependency on a reference checkout.

Direct setup, postprovision, and runbook validation require an expected tenant
via `-TenantId` or `AZURE_TENANT_ID`, as well as the selected subscription.
Preprovision carries the selected azd environment's tenant into the shared
wizard; preup uses the canonical guard before resource-group creation.
The shared helper reads fresh ARM subscription metadata and rejects absent or
mismatched identities, unreadable metadata, and every state except `Enabled`.
Cached CLI account state does not establish eligibility. ARM tokens are bound
to the intended subscription and tenant, and Exchange setup passes the validated
tenant explicitly into its Outlook token helper. No global CLI default changes.

`tests/TargetGuardEntrypoints.Tests.ps1` executes the maintained scripts with
real vendored guards and offline boundary stubs/tripwires, including deliberately
unrelated CLI defaults and stale cached Enabled state. These checks supplement
the preservation, locked-package, report, drift-isolation, and ownership suites.
They do not authorize permission grants or substitute for Codex-owned native
sub-mvp validation, runbook publication/access checks, or owned-resource cleanup.
