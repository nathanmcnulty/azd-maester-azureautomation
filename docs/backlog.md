# Backlog: nathanmcnulty/azd-maester-azureautomation

> Generated from `docs/backlog.json`. Edit the JSON source and regenerate this file.
> Standard: [azd agent backlog standard](https://github.com/nathanmcnulty/azd-reference/blob/main/standards/agent-backlogs.md). This link is review guidance, not a runtime dependency.

- **Schema version:** 1.0.0
- **Repository:** nathanmcnulty/azd-maester-azureautomation
- **Source revision:** `5b0a8ad9c5a6ac2153b95ee1e596de5daa17ab71`
- **Captured:** 2026-10-17
- **Items:** 10

## MAUTO-001: Reconcile this backlog with current source and active work

- **Kind:** discovery
- **Priority:** P1
- **Status:** done
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Plans and implementation evidence are spread across files; the captured source can change while other tasks work.

**Scope:**

- docs/backlog.json
- docs/backlog.md
- Existing roadmap, execution status, open issues and pull requests &lpar;read-only&rpar;

**Acceptance:**

- Classify each candidate as implemented, still open, superseded or awaiting evidence; retain source links and reasons.
- Inspect dirty state, remotes, worktrees and local environment presence without reading secrets; avoid duplicate work with active owners.
- Resolve the actual offline validation commands and record exact current default-branch/working-tree provenance; do not copy historical live passes to newer code.

**Validation:**

- git status --short
- git remote -v
- git worktree list --porcelain
- Read the applicable instructions and validation workflow; read gh issue list and gh pr list for the named repository using nathanmcnulty. Do not create or modify issues/PRs.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- README.md

**Evidence:**

- Reconciled later reviewed metadata tip ec243a79c1a9370c08efc476f056dd1dafcc523e against freshly fetched origin/main 4ef4820ff355ab4ae4eddd3bfb27297ae56a8acc. Current main adds reviewed source fixes from pull request&lpar;s&rpar; &num;15, &num;17 and &num;19; no dirty canonical bytes or unrelated branch history were copied.
- Current repository issues and pull requests were read on 2026-10-04&colon; none are open. Items MAUTO-002, MAUTO-003 remain proposed because their component, host-specific live, or shared azd-maester issue gates are not satisfied by source merges alone; completed issue-backed fixes retain exact issue and pull-request evidence.
- Full current-source offline Pester validation passed 48/48 tests with zero failures. Canonical backlog schema and generated-Markdown checks also passed; no Azure, Graph, deployment, report publication or other live operation was performed.

**Review and authorization note:**

Review MAUTO-001 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MAUTO-005: Pin the complete Automation runtime package set for reproducible deployment

- **Kind:** discovery
- **Priority:** P1
- **Status:** done
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The report captured on 2026-10-03 is closed after the reviewed fix merged; this record preserves the original trigger and validation boundary.

**Scope:**

- Linked issue and current source &lpar;read-only&rpar;
- Repository-local backlog evidence

**Acceptance:**

- Read the linked issue and current default branch; classify the exact defect, current owner and evidence gap.
- Record a current PR or verified resolution before selecting any implementation; preserve broader feature and live acceptance gates.

**Validation:**

- Read current issue and PR state using nathanmcnulty; do not modify or close issues during reconciliation.
- Inspect dirty state and worktrees; resolve the exact current revision and relevant offline commands before implementation.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester-azureautomation/issues/10

**Evidence:**

- GitHub issue &num;10 is closed by merged pull request &num;12; current origin/main 4ef4820ff355ab4ae4eddd3bfb27297ae56a8acc contains the reviewed fix. Source closure does not claim a new live deployment, report publication, or human-visible result.

**Review and authorization note:**

Review MAUTO-005 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MAUTO-004: Failed Maester execution can publish a completed report and pass runbook validation

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The report captured on 2026-10-03 is closed after the reviewed fix merged; this record preserves the original trigger and validation boundary.

**Scope:**

- Paths and trigger cited in the linked issue
- Focused offline regression tests
- docs/
- docs/backlog.json
- docs/backlog.md
- BACKLOG.md

**Acceptance:**

- Classify the report as still reproducible, already fixed, superseded or requiring live evidence; record the exact current revision.
- For a reproducible defect, demonstrate the linked trigger with an offline regression and apply the smallest fix preserving tenant/target/ownership and failure semantics.
- For a feature, produce a bounded design with compatibility, optional permissions, acceptance and rollout gates before implementation; no live mutation or automatic issue closure.

**Validation:**

- Read the issue body and current source/PRs; capture the exact reproduction and existing registered offline validation command.
- Use deterministic fixtures for the described trigger and negative boundary; retain current-source results. Do not rerun production or tenant operations to reproduce it.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester-azureautomation/issues/9
- README.md

**Evidence:**

- Merged fix&colon; https&colon;//github.com/nathanmcnulty/azd-maester-azureautomation/pull/11 closed issue &num;9 at f799869fa5f8465b76b8dfffe851b81a3c9e234f; the fix is present on current main c50ed1f9f5ce34d2567b2708e86fd54998328661.
- Current-head source propagates Invoke-Maester errors, rejects missing genuine reports and fails required latest publication&colon; https&colon;//github.com/nathanmcnulty/azd-maester-azureautomation/blob/c50ed1f9f5ce34d2567b2708e86fd54998328661/scripts/Invoke-MaesterAutomationRunbook.ps1&num;L426-L494
- Deterministic regression coverage includes thrown invocation, missing report, genuine findings and failed publication&colon; https&colon;//github.com/nathanmcnulty/azd-maester-azureautomation/blob/c50ed1f9f5ce34d2567b2708e86fd54998328661/tests/RunnerFailure.Tests.ps1&num;L43-L88 and https&colon;//github.com/nathanmcnulty/azd-maester-azureautomation/blob/c50ed1f9f5ce34d2567b2708e86fd54998328661/tests/WebAppFailure.Tests.ps1&num;L43-L56
- Exact current-main validation passed&colon; https&colon;//github.com/nathanmcnulty/azd-maester-azureautomation/actions/runs/37145474192/job/111268384908
- Live evidence gap preserved&colon; PR &num;11 leaves Azure Automation platform status propagation as an integration follow-up; this reconciliation claims no live Automation run.
- GitHub issue &num;9 is closed by merged pull request &num;11; current origin/main 4ef4820ff355ab4ae4eddd3bfb27297ae56a8acc contains the reviewed fix. Source closure does not claim a new live deployment, report publication, or human-visible result.

**Review and authorization note:**

Review MAUTO-004 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MAUTO-008: Enforce the PowerShell 7.6 and Pester 6.2 authoring baseline

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The runtime upgrade selects PowerShell 7.6, but maintained scripts lacked a minimum-version guard and repository CI still selected Pester 5.7.1.

**Scope:**

- Owned scripts/&ast;.ps1 entry points
- Repository validation workflow and developer guidance

**Acceptance:**

- Require PowerShell 7.6+ before owned script bodies execute; preserve immutable vendored sources and historical receipts.
- Install and import exact Pester 6.2.0 in CI and document equivalent local validation.
- Run the full offline suite on the supported baseline; retain separate live runtime/preservation gates.

**Validation:**

- Invoke-Pester -Path ./tests -CI with PowerShell 7.6+ and imported Pester 6.2.0
- Parse all PowerShell and inspect ScriptRequirements for every owned script; verify permission evidence hashes and canonical backlog checks.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester-azureautomation/issues/24
- https&colon;//github.com/nathanmcnulty/azd-maester-azureautomation/pull/26
- docs/development.md
- https&colon;//github.com/nathanmcnulty/azd-maester-azureautomation/pull/28
- https&colon;//github.com/nathanmcnulty/azd-maester-azureautomation/blob/c53cbe1e484fbf26e9834fe202783a934f849523/docs/backlog.json

**Evidence:**

- 2026-10-16&colon; Source follow-up based on runtime PR26 head 36804911c0ea8de8f301a6f4ec6ba995c8c55124. All nine owned scripts enforce PowerShell 7.6 before execution. Vendored scripts, runtime package locks and historical evidence are unchanged.
- PowerShell 7.6.6 with actual Pester 6.2.0&colon; all 75 repository tests passed, zero failed or skipped. This is offline source evidence; it does not establish native runtime startup, runbook preservation or workload execution. Existing runtime/preservation PRs and live gates remain open.
- Renumbered the authoring-baseline task to MAUTO-008 to preserve viewer tasks MAUTO-006/007 already allocated in reviewed pending preservation branch c53cbe1e484fbf26e9834fe202783a934f849523. Both original viewer records remain proposed and unchanged; this is metadata reconciliation, not viewer implementation or authorization.
- 2026-10-17 reconciliation&colon; merged Automation origin/main 5b0a8ad9c5a6ac2153b95ee1e596de5daa17ab71 into the PS7.6 branch without adopting the separate azd-reference main candidate 3f88050. The current merged source has eleven maintained PowerShell entry/helper scripts, exact Pester 6.2 CI and the pinned Bicep preservation check; the full offline suite passed 582/582 on PowerShell 7.6.6 with BICEP&lowbar;EXE bound to the local v0.42.1 executable. Permission evidence was checked against current bytes and only the Setup-PostDeploy.ps1 hash required refresh; requirements and grants were unchanged.

**Review and authorization note:**

Review MAUTO-008 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MAUTO-003: Reconcile shared hook/webapp versions and host permission deltas

- **Kind:** maintenance
- **Priority:** P2
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Existing adoption must be updated through hashes and host-specific validation rather than blindly reinstalling components.

**Scope:**

- azd-components.lock.json
- azd-permissions.json
- scripts/
- infra/
- docs/

**Acceptance:**

- Compare lock pins with canonical manifests and current-source drift before proposing an update.
- Run target-context negative cases and compare minimal versus optional-feature permissions.
- Keep Maester execution and reporting host-specific; record exact source hashes and candidate/pilot status.

**Validation:**

- Invoke-Pester ./tests/TargetContext.Tests.ps1 -CI
- Read and compare lock hashes with canonical reference source; do not overwrite drift.

**Dependencies:**

- _none_

**Components:**

- maester-azd-hooks
- maester-report-webapp

**Sources:**

- README.md
- azd-components.lock.json

**Evidence:**

- Adopted pilot maester-azd-hooks 0.1.6 from immutable azd-reference revision a09cac311aac7362f56d2a31833ed90ce5812649. All eight managed targets match the component manifest and lock; only Maester-UpWizard.psm1 changed from 0.1.5, to require a non-empty GUID before persisting the optional Web App group Object ID.
- Preserved maester-report-webapp 0.1.1 at immutable revision 79f0608c672639aae0f0ed96d160b1eb17cfc08f with exact vendored hash 4b12708c76489f3f20e031fdafc706a3062276ef4a83fda7f5109f4cbd902972.
- Added a schema-valid partial permission manifest with exactly 24 source-proven declarations&colon; eight Minimal runtime roles, eleven additional default Extended roles, four deployment-operator scopes, and optional Mail.Send. Working and raw-index comparisons returned 8/19/20/4 permissions with no evidence findings; comparisonComplete remains false and explicit gaps preserve unmodeled Azure RBAC, optional feature, operator and cleanup authority.
- The 0.1.6 permission helper is byte-identical to 0.1.5 at SHA-256 e43b6e4ce60c9adef30355cc126519e5f754c01630c94fca9d85c04aebde3548; this adoption adds no declared scope or grant and claims no effective tenant permission.
- Offline validation passed&colon; TargetContext 5/5, full host suite 48/48, PowerShell parse 24 files with zero errors, Bicep compilation to valid JSON SHA-256 3f29d9adc005c8ee144f93336a2312dd6fc0577087a5f924bcd64cc31f5cd690, canonical permission comparison tests 9/9, component/lock drift checks, backlog schema, generated Markdown and diff checks.
- No Azure, Graph, deployment, report publication or live host operation was performed. Host-specific live execution, report access and cleanup remain under item 002 and are unchanged.

**Review and authorization note:**

Review MAUTO-003 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MAUTO-002: Qualify Automation runbook execution and optional report-webapp lifecycle

- **Kind:** verification
- **Priority:** P1
- **Status:** proposed
- **Wave:** 2
- **Authorization:** azure-deployment
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Shared pilots are already vendored; host-specific execution and report access still need independently bound evidence.

**Scope:**

- scripts/Invoke-RunbookValidation.ps1
- docs/
- infra/
- tests/TargetContext.Tests.ps1

**Acceptance:**

- Record exact Maester/runtime/component revisions and host execution output under the selected tenant.
- Validate optional webapp identity, report publishing, Easy Auth and feature-specific permission delta.
- Disabled web hosting works independently; cleanup preserves adopted objects and records exact owned resources.

**Validation:**

- Invoke-Pester ./tests/TargetContext.Tests.ps1 -CI
- After separate authorization use ./scripts/Invoke-RunbookValidation.ps1 against the exact owned host; retain report access and cleanup evidence.

**Dependencies:**

- _none_

**Components:**

- maester-azd-hooks
- maester-report-webapp

**Sources:**

- README.md
- scripts/Invoke-RunbookValidation.ps1

**Evidence:**

- _none_

**Review and authorization note:**

Review MAUTO-002 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MAUTO-009: Keep configuration drift disabled and isolated by default

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 3
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Omitting DriftRoot leaves upstream Maester able to discover unapproved input from an inherited process environment variable.

**Scope:**

- scripts/Invoke-MaesterAutomationRunbook.ps1
- tests/DriftIsolation.Tests.ps1
- docs/drift-isolation.md
- docs/backlog.json
- docs/backlog.md

**Acceptance:**

- Exclude the locked upstream drift file before Pester discovery and clear its ambient environment during invocation, restoring prior process state on success and failure.
- Preserve ordinary assessment, genuine findings, publication and failure semantics; do not enable drift, fetch data or add permissions.
- Prove the original inherited-input defect and corrected isolation with exact production configuration/invocation tests plus actual locked suite/report qualification.

**Validation:**

- PowerShell 7.6+ and Pester 6.2&colon; Invoke-Pester ./tests -CI
- Parse all PowerShell; canonical backlog schema/render checks; fixtures are not native job or publisher proof.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- docs/drift-isolation.md
- https&colon;//github.com/nathanmcnulty/azd-maester/blob/090001c61660d6522d2c5d4df6581af297015b35/docs/drift-analysis-design.md
- https&colon;//github.com/nathanmcnulty/azd-maester/issues/2

**Evidence:**

- PowerShell 7.6.6/Pester 6.2.0 full repository validation passed 79/79 with zero nonpasses; parser and differential analyzer checks found no new supported-runtime issue. Three isolation regression cases fail against the original runner, and all four pass with the fix.
- Actual offline locked Maester 2.2.0 Invoke-Maester qualification used this host production configuration/invocation blocks, an unchanged hash-verified upstream suite, one ordinary synthetic test and an inherited unapproved input folder. Exactly one ordinary test passed, drift stayed excluded, the inherited environment was restored, and no HTTP/authentication tripwire fired. Qualification supplies offline connection flags and invokes only assessment blocks; publisher paths are outside this check, and no native job, workload identity, Blob publication/access or cleanup outcome is claimed.
- Default-disabled isolation only; MAUTO-010 retains the approved-input adapter, normalization/privacy and native qualification gates. Existing runtime/deployment validation evidence is preserved.
- 2026-10-17 reconciliation&colon; default-disabled drift isolation now clears and restores MAESTER&lowbar;FOLDER&lowbar;DRIFT with PowerShell NullString semantics, preserving absent, empty and nonempty process states across success and throw. Drift regression coverage passed 5/5 and the full Pester 6.2 suite passed 582/582; locked Maester absent, empty and inherited qualifications each retained one ordinary assessment result with no HTTP/authentication activity. No collector, permission or live publication authority was added.

**Review and authorization note:**

Review MAUTO-009 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MAUTO-006: Implement optional Caddy Container App report viewer

- **Kind:** feature
- **Priority:** P2
- **Status:** proposed
- **Wave:** 4
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The shared viewer design is complete, but this standalone Automation runner has no Caddy provider implementation.

**Scope:**

- infra/
- scripts/
- docs/
- azd-permissions.json

**Acceptance:**

- Add exact -IncludeContainerWebApp mapping, default-off and exclusive with both other viewer flags, including legacy -IncludeWebApp; preserve existing hooks and deployment-validation behavior.
- Use only an immutable signed image/SBOM and reviewed versioned azd-reference component pin; publish a private bounded HTML projection plus manifest with ETag/conditional pointer, BlobDataContributor only where required, and viewer managed identity read-only.
- Bound Caddy paths, fixed loopback GET/HEAD routes with no shared report volume, size/poll/LKG/atomic switch, HTTPS and native tenant/audience group authorization; reject missing/overage groups, foreign tenant, forged headers and host bypass. Record owned rollback/deletion receipts and validate with offline fixtures before authorized lab writes.
- Use a dedicated viewer-projection container with immutable HTML/manifest versions and an ordered ETag-conditional latest pointer. Assume all app containers can use attached identities; expose no archive, Graph or resource-write privilege to the viewer.
- Before feature completion, pass the design native gates in the authorized lab with concrete tenant/subscription/group/test users&colon; allowed and denied report/asset/host access, exact report bytes, concurrency/staleness, provider-specific rotation/cold start, rollback and ownership-aware cleanup. Preserve failed evidence; no live success claim from fixtures.

**Validation:**

- Run the existing standalone validation workflow and new offline native fixtures; fixtures do not prove live auth, provider acceptance or report receipt.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester/blob/main/docs/report-viewer-design.md
- https&colon;//github.com/nathanmcnulty/azd-maester/issues/5

**Evidence:**

- _none_

**Review and authorization note:**

Review MAUTO-006 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MAUTO-007: Implement optional Static Web Apps Standard report viewer

- **Kind:** feature
- **Priority:** P2
- **Status:** proposed
- **Wave:** 4
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The shared viewer design is complete, but this standalone Automation runner has no Static Web Apps provider implementation.

**Scope:**

- infra/
- scripts/
- docs/
- azd-permissions.json

**Acceptance:**

- Add exact -IncludeStaticWebApp mapping, default-off and exclusive with both other viewer flags, including legacy -IncludeWebApp; preserve existing hooks and deployment-validation behavior.
- Use Standard/custom tenant issuer and a reviewed Report.Reader role-source function/claim mapping with fail-closed missing, invalid and overage claim behavior; do not add tenant-wide Graph reads.
- Keep end-user UAMI/FIC distinct from the high-trust deployment-token publisher; bind fixed safe HTML, auth config, hash, revocation/reset and owned teardown receipts. Validate offline before authorized lab writes.
- Qualify the documented preview/support posture of function-based role assignment. Keep site-deployment authority and token access out of Maester runners&colon; a separate trusted publisher must bind fixed auth/function config hashes and reject report-supplied config or code.
- Before feature completion, pass the design native gates in the authorized lab with concrete tenant/subscription/group/test users&colon; allowed and denied report/asset/host access, exact report bytes, concurrency/staleness, provider-specific rotation/cold start, rollback and ownership-aware cleanup. Preserve failed evidence; no live success claim from fixtures.

**Validation:**

- Run the existing standalone validation workflow and new offline native fixtures; no deployment or delivery claim is made.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester/blob/main/docs/report-viewer-design.md
- https&colon;//github.com/nathanmcnulty/azd-maester/issues/4

**Evidence:**

- _none_

**Review and authorization note:**

Review MAUTO-007 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MAUTO-010: Implement approved data-only configuration drift inputs

- **Kind:** feature
- **Priority:** P2
- **Status:** proposed
- **Wave:** 4
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Upstream drift comparison exists, but this host has no approved artifact/target/privacy contract or live qualification.

**Scope:**

- scripts/Invoke-MaesterAutomationRunbook.ps1
- tests/
- docs/
- azd-permissions.json

**Acceptance:**

- Follow the reviewed MCAT-011 design&colon; explicitly enabled data-only artifacts, immutable approved baseline, tenant/environment/run/source/hash/freshness binding, bounded JSON/path/link/duplicate validation and reviewed schemas, normalization and exclusions.
- Use the actual locked upstream suite with expected positive case counts and fail on missing suite, zero cases, malformed/scalar/settings inputs, comparison errors and container failures; preserve default-off isolation and reused-process environment restoration.
- Inspect actual HTML/JSON/Markdown/logs for planted sensitive values; preserve separate comparison, report and publication outcomes and rollback. Add no automatic capture, baseline update or remediation.
- Independently review the adapter and qualify authorized native job execution, report access, rollback and exact owned cleanup; coordinate a second host before shared extraction.

**Validation:**

- PowerShell 7.6+/Pester 6.2 registered tests and actual locked suite/report fixtures.
- Separate authorized native host/report/access/cleanup qualification; local metadata grants no live authority.

**Dependencies:**

- MAUTO-009

**Components:**

- _none_

**Sources:**

- docs/drift-isolation.md
- https&colon;//github.com/nathanmcnulty/azd-maester/blob/090001c61660d6522d2c5d4df6581af297015b35/docs/drift-analysis-design.md
- https&colon;//github.com/nathanmcnulty/azd-maester/issues/2

**Evidence:**

- _none_

**Review and authorization note:**

Review MAUTO-010 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.
