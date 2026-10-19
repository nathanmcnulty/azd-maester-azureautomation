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

After qualifying the host under the runtime policy below, the runbook follows its existing
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

### Supported service host and stable runtime policy

Fresh and existing lab Automation accounts configured for PowerShell 7.6 reported
`7.6.0-preview.5`, Core, and .NET `10.0.9`. The fresh-account runtime-only check
also imported all seven real locked default packages successfully. The maintained
runbook therefore supports this exact observed service host for ordinary assessment
as well as runtime-only validation. This is a bounded compatibility exception,
not a claim that the host reports a stable PowerShell version.

One qualification gate runs before downloads, imports, filesystem work, or workload
authentication. It accepts Core with either:

- A stable PowerShell release at least 7.6 on .NET 10 or newer.
- Exactly `7.6.0-preview.5` (case-sensitive, with no added version suffix) on .NET 10.

Every other prerelease is rejected, including newer minor/major previews. Both
normal execution and `-RuntimeValidationOnly` use the same gate. Runtime-only mode
still returns immediately after the seven verified imports, and its JSON receipt
retains the actual observed PowerShell and .NET versions. Normal execution proceeds
to its unchanged managed-identity connections and workload checks; this host policy
does not authorize or bypass any workload, permission, publication, or delivery gate.

`AllowRuntimeValidationPreview` remains accepted for compatibility with earlier
diagnostic callers, but is no longer needed to qualify the observed host. It still
requires `RuntimeValidationOnly` when set to true and cannot enable any additional
host. New import-only checks need only `-RuntimeValidationOnly`.

Azure Automation documents
[PowerShell 7.6 GA in July 2026](https://learn.microsoft.com/en-us/azure/automation/whats-new#july-2026).
Track the service/version discrepancy and eventual exception removal in
[issue #45](https://github.com/nathanmcnulty/azd-maester-azureautomation/issues/45).
Offline entrypoint tests substitute version metadata and isolated package fixtures;
they prove gate and branch behavior, not native assessment success. Full workload
execution, identity permissions, optional integrations, report delivery, and cleanup
remain separate native acceptance gates.
