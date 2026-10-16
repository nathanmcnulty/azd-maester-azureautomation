# Existing-deployment upgrade preservation

A normal provision still creates the complete solution. When preprovision verifies an existing, receipt-bound (or explicitly adopted) Automation deployment, it reads the live schedule, published PowerShell runbook, and jobSchedule association before ARM runs. Existing schedules and runbooks are omitted from ARM entirely. Postprovision updates only the existing runbook runtime binding through a guarded PATCH when it differs from the declared target. Postprovision never PUTs an existing association, preserving parameters and `runOn`. Matching local/published runbook content skips draft upload and publication.

The ownership checks fail closed on unreadable, malformed, paginated, missing, conflicting, or ambiguous resources. A saved environment flag is not ownership evidence. A missing previously owned association, schedule, or published runbook requires reconciliation; it is never silently recreated. Existing adoption requires the exact live account ID, managed-identity principal ID, and association GUID. Do not manufacture receipts to bypass these checks.

Azure Automation [jobSchedule GET responses](https://learn.microsoft.com/en-us/rest/api/automation/job-schedule/get?view=rest-automation-2024-10-23) can omit top-level `name` and `type`. Association identity therefore requires the exact full resource ID and matching `properties.jobScheduleId`; any supplied name/type must agree. The required GUID is never recovered from a label, raw responses are not rewritten, and a replacement GUID still requires explicit reconciliation even when schedule/runbook linkage is unchanged. Schedule and runbook resource checks remain strict.

## Bounded runtime-only mode

For an existing verified deployment, explicitly set:

```powershell
azd env set AUTOMATION_UPGRADE_PRESERVE_ACCESS true
```

This mode changes only the Automation runtime environment, its package resources, and the runbook runtime binding. It omits account, storage, web app, lock, variable, role-assignment, and other non-runtime infrastructure writes. It also bypasses all postdeployment Graph/Exchange/Teams/Azure grants, the deploying user's storage grant, Easy Auth, application/service-principal setup, and consent. Existing setup statuses and assignment receipts are retained. Before ARM and again before postdeployment writes, the published script must match the checked-in local workflow after BOM/CRLF normalization. A mismatch reports hashes and stops; runtime-only mode never authorizes replacing a different script. Review and separately authorize any script update outside this mode before retrying. Exact existing storage, optional Web App, account, and identity outputs are still validated. The mode rejects a new or unverified deployment and cannot change Web App deployment mode.

This is not a full solution upgrade. Desired changes to non-runtime infrastructure and permissions are intentionally outside this mode. Return to the normal provisioning flow only when those changes are intended and authorized:

```powershell
azd env set AUTOMATION_UPGRADE_PRESERVE_ACCESS false
```

`AUTOMATION_EXISTING_RESOURCES` is a derived preprovision value, not a user-supplied adoption mechanism. It is refreshed from live reads and advances after a successful first association. Conflicting process and selected-environment controls fail rather than silently changing mode.

## Explicitly adopted custom metadata

A deployment whose `solution` tag was explicitly customized can use `AUTOMATION_ADOPT_SOLUTION_TAG` to state the exact expected value. This is accepted only in runtime-only preservation mode and only with a complete selected-environment ownership receipt or explicit account/principal/jobSchedule adoption triplet. Every stage rechecks the live account identity and association; a flag or matching tag alone never establishes ownership. No historical alias is assumed, no tag is inferred from the live resource, and no resource is retagged. Canonical fresh/full provisioning still requires `automation-account`. Clear the explicit tag before returning to that flow.

Preservation preflight also verifies the exact resource-group identity and evaluates the template's deterministic storage/Web App names locally using the existing Bicep CLI. `STORAGE_ACCOUNT_NAME`, and `WEB_APP_NAME` when enabled, must match those targets. The Automation `StorageAccountName` variable is an externally configured report destination; it is left unchanged and cannot supply deployment ownership or replace missing outputs.

This local evaluation requires an already installed Bicep CLI supporting `using none` (0.31.0 or newer). Set `BICEP_EXE`, put the executable on PATH, or use Azure CLI's existing Bicep installation. The hook never installs a tool or invokes Azure to evaluate the naming expression. It isolates compiler inputs from inherited parameter overrides, preserves the exact ARM resource-group ID casing, and fails closed when evaluation or output verification fails.

## Existing runbook runtime updates

Live validation showed that an existing-runbook create-or-update PUT can leave the runbook in `Edit`, even without a content link; omitting metadata can also reset tags, description and logging. Existing runbooks are therefore never PUT by ARM. Fresh deployments keep their original bootstrap/default creation path.

After the runtime/packages deploy and the local-content check succeeds, postprovision uses Microsoft's documented [direct runtime-environment update](https://learn.microsoft.com/en-us/azure/automation/manage-runtime-environment#update-runbook). The PATCH body contains only `properties.runtimeEnvironment`. Its desired name/version come from the declared runtime resource's deployment outputs, with no process fallback or inference from the current binding. The exact runtime must exist under the verified Automation account and match its ID, name, type, PowerShell language and version. Missing or inconsistent outputs stop setup.

Immediately before PATCH, fresh exact reads must still show the receipt-bound association, unchanged schedule, and a Published PowerShell runbook whose published content matches the local workflow after BOM/CRLF normalization. A local metadata snapshot compares location, tags, description and logging after PATCH; published state, runtime binding, content, schedule and association are checked separately. These snapshots are never inserted into an ARM parameter document. The retired `AUTOMATION_EXISTING_RUNBOOK_METADATA` value is ignored, including stale values containing quotes, newlines, backslashes or `${...}` text.

An already-bound runbook skips PATCH. Any pre-existing `Edit` state still stops before deployment; a provider transition to `Edit` or any unexpected readback stops after PATCH. This flow never recovers, uploads, or publishes an arbitrary draft. A previously interrupted PUT that left `Edit` needs separate evidence-bound reconciliation and authorization. The direct PATCH's provider behavior remains a live acceptance gate; documentation and mocks do not establish it.

## Explicit validation-job control

Normal deployments retain the existing default of running validation. A local override takes precedence over the shared wizard's `VALIDATE_RUNBOOK_ON_PROVISION` setting:

```powershell
azd env set AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION false
```

With `false`, postprovision starts no validation job and the summary says `Skipped`. To authorize a single validation invocation, set it to `true` for that invocation, then explicitly restore `false` before repeating. This is an explicit control, not an automatically consumed one-shot token. A validation job runs the real report workflow, including storage writes and any configured email recipient; approve those effects before enabling it.

## Required live acceptance gate

Offline tests prove emitted request shapes and hook behavior, not Azure provider semantics. In particular, the direct runtime-only PATCH must be verified to retain Published state, published content and metadata while changing `runtimeEnvironment`. Do not treat the candidate as live-accepted before this gate.

1. Select and independently verify the intended existing azd environment, subscription, tenant, account, and managed identity. Snapshot exact account/runbook/runtime identities, published bytes and SHA-256, full schedule configuration and enabled state, all associations (including parameters/`runOn`), grants, Easy Auth, setup statuses/receipts, and existing job IDs. Preserve the old runtime and rollback artifact.
2. Enable bounded runtime-only mode and disable validation. Inspect the compiled template/preview: no active runbook, schedule, association, grant, account/storage/web, or other non-runtime ARM writes. Verify the declared runtime name/version outputs and the later single-property PATCH target. Stop on any unexpected target or difference. Keep deployment mode incremental; do not use complete mode or teardown.
3. Perform the approved deployment in the actual target. Compare full snapshots and confirm only the intended runtime binding/packages changed. Verify Published state, published runbook bytes and preserved metadata immediately, including after an interrupted postprovision path where feasible. A provider reset or missing resource is a blocker, not a successful test.
4. When the specific validation job and its report/email effects are authorized, enable validation for one invocation, record its job ID/outcome, and restore the override to `false`. Retain the pre-existing weekly schedule exactly, including an enabled Sunday 10:34 UTC schedule or any disabled/custom configuration.
5. Repeat normal provision with validation disabled. Also repeat an approved actual ARM redeployment with `azd provision --no-state`, because azd may skip ARM when its template/parameter state is unchanged. Compare snapshots again and prove no additional runtime PATCH when already bound, validation job, association PUT, seed publication, grants, or schedule drift. Cached repeat success alone is insufficient.
6. If acceptance fails, stop. Use the previously approved rollback artifact to rebind the retained old runtime, verify published bytes and schedule/association state again, and retain failure evidence. No runtime deletion is part of this change.

This candidate is limited to this repository. Vendored shared hooks and the Web App component are unchanged.
