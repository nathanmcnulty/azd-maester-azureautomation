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

## Runtime-only runbook validation

Issue #32 adds a default-off `RuntimeValidationOnly` Boolean to the maintained
`Invoke-MaesterAutomationRunbook.ps1`. For an approved native bootstrap check,
use the existing `Invoke-RunbookValidation.ps1` with the explicit
`-RuntimeValidationOnly` switch and the same required target selectors. The helper
still authenticates to the scoped ARM control plane and starts a real Automation
job; the runbook itself stops before workload authentication.

The helper submits `properties.parameters = {"RuntimeValidationOnly":"true"}`:
the value is the string containing the JSON Boolean `true`, matching the
[Azure PowerShell job parameter serializer](https://github.com/Azure/azure-powershell/blob/main/src/Automation/Automation/Common/AutomationPSClient.cs)
and [Automation job API](https://learn.microsoft.com/en-us/rest/api/automation/job/create?view=rest-automation-2023-11-01).
Omitting the switch, or supplying `-RuntimeValidationOnly:$false`, submits `{}`
and preserves ordinary assessment behavior. For direct local invocation of the
runbook, pass the actual Boolean `-RuntimeValidationOnly:$true`, not a string.

After enforcing PowerShell 7.6+ Core / .NET 10+, the runbook follows its existing
package download, SHA-256 verification, extraction and exact-path import flow.
Only after all seven default imports succeed does this mode emit one compact JSON
receipt (`Kind: Maester.RuntimeValidation`, schema 1) with actual PowerShell/.NET
versions and each imported module's name, version, path and module base. The start
message remains a separate output record. A missing package, bad hash or failed
import throws without a success receipt. No Automation variables, identity
connections, assessment, report publication or notification are reached.
Exchange and Teams retain their separate optional gates and are not included in
the receipt. All nine package locks remain unchanged.

Offline tests execute the actual entrypoints using strict boundary stubs and tiny
local package fixtures; these tests do not qualify real Gallery modules or Azure
sandbox behavior. Native PowerShell 7.6 availability, published source/parameter
binding, seven real package imports and receipt inspection remain Codex-owned
sub-mvp gates. Managed identity, optional workloads, assessment, report access,
retention/rollback and owned cleanup remain separate gates. This mode neither
publishes changed runbook content nor bypasses the existing preservation contract.

### Temporary service-preview import validation

An existing lab Automation job configured for PowerShell 7.6 reported
`7.6.0-preview.5`, Core, and .NET `10.0.9`. This is an observation of that host,
not proof of the default in newly deployed accounts. Azure Automation documents
[PowerShell 7.6 GA in July 2026](https://learn.microsoft.com/azure/automation/whats-new#july-2026).

For a bounded import-only diagnostic on that exact host, pass both
`-RuntimeValidationOnly -AllowRuntimeValidationPreview` to the validation helper.
Both options default off. The helper submits
`{"RuntimeValidationOnly":"true","AllowRuntimeValidationPreview":"true"}`.
The additional exception matches only `7.6.0-preview.5`; Core and .NET 10+
remain required. Using the preview option without runtime-only mode fails before
any job creation or runbook work. Ordinary assessment retains its existing version gate and does not receive
this exception. Receipts retain the observed version, so preview-host import evidence must
not be described as stable-host qualification. Reevaluate this temporary option
once a fresh-account host observation and the service/runtime discrepancy are
resolved; do not generalize it to other prereleases.
