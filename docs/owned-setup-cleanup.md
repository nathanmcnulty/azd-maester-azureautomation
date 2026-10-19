# Setup ownership and teardown evidence

Setup now keeps a deployment-bound ownership journal under the selected local
azd environment. The journal is not an authorization token and must not be
copied from another environment or edited to manufacture ownership.

## Setup guarantees

- Plan-only setup neither initializes the journal nor changes remote state.
- After the operator approves the exact plan, setup acquires an exclusive
  lifecycle lock and rechecks the exact ARM targets before applying access.
  The lock remains held through subsequent runtime publication.
- Before opening the setup journal, Apply durably marks a ready infrastructure
  receipt as having begun external setup. Missing setup evidence cannot later
  be mistaken for a provision-only deployment.
- Every supported access operation records a durable pending intent before its
  provider write. A successful response is checkpointed with its exact IDs
  before another operation runs. ARM assignment IDs are selected before PUT.
  Returned identity tuples and supported configuration afterstates are then
  verified. A contradiction or failed readback retains the exact IDs as a
  conflict and stops subsequent writes.
- A newly created Easy Auth app records its approved initial redirects, identifier
  URIs, group claims, token settings, and single-tenant audience. Unexpected later
  configuration or owners block teardown rather than being silently removed.
- Existing receipts are retained on successful no-op reruns. Legacy environment
  assignment lists are retained as recovery information; they do not establish
  new deletion authority.
- A failed request, unknown creation response, or failed checkpoint stops the
  sequence. A second write to an already active journal target also requires
  explicit reconciliation rather than overwriting its receipt. Pending operations
  are not silently treated as absent or adopted
  using a matching name. Reconcile their exact service state before retrying.
- The journal contains allowlisted identities and configuration metadata, never
  ARM/Graph tokens, storage keys, connection strings, or unrestricted provider
  response/configuration objects.

The setup client is a separately administered prerequisite. The selected report
security group is also pre-existing. Neither is deployment-owned. Reused Easy
Auth applications and service principals remain distinct from new objects
created by this deployment.

Changes to a reused application's configuration or existing delegated grant
record sanitized before/after values and their exact target. They are not a
reason to delete the reused application. Unsupported or conflicting restoration
must remain a visible cleanup blocker. A mutation on a journal-owned parent can
be covered by that parent's verified removal; newly created children retain
independent exact ownership receipts.

Automation's existing preserve-access upgrade keeps its access and schedule
receipts unchanged. If a setup journal already exists, the upgrade uses its
lifecycle lock without changing its entries. Legacy upgrades without that journal
retain their previous reviewed behavior; automatic ownership-aware external
teardown requires separate recovery evidence rather than reconstructed ownership
from environment IDs.

## Before/after acceptance matrix

| Starting state / action | Required result |
| --- | --- |
| Plan only or declined access approval | No setup marker, journal initialization, access write, or publication |
| Successful Apply followed by no-op Apply | Exact earlier owned IDs retained; no duplicate grant or replaced ownership history |
| A response contradicts its approved tuple or exact readback fails | Completed exact IDs retained as conflict; later writes stop |
| A new EasyAuth app gains unreviewed configuration | Cleanup blocked before any delete; complete original creation baseline retained |
| A provider write fails or returns no usable creation ID | Earlier receipts remain applied; current operation remains pending; subsequent writes and blind retry stop |
| Fresh dedicated ARM deployment with exact owned locks | Preview exact inventory; separate approval removes only owned locks; cancellation afterward leaves those locks removed |
| Direct postdown while the bound RG or runtime still exists | External cleanup blocked; no authorization DELETE |
| Owned Graph/Teams/Azure roles after confirmed ARM absence | Exact tuple checked; delete only recorded IDs, or recognize provider-confirmed cascade absence; checkpoint each completion |
| Owned Exchange principal/RBAC and new EasyAuth app/SP/grant | Exact owned identities removed and absence verified; unexpected dependencies or changed tuples block deletion |
| External setup client, report group, or reused EasyAuth objects | Retained; unsupported shared configuration/grant restoration blocks cleanup instead of deleting an adopted parent |
| Provision-only deployment with no external setup begun | Require its independent ready infrastructure receipt; missing external evidence after setup began must never enter this path |
| Partial postdown failure followed by retry | Preserve completed/deleting records; require a fresh plan; resume remaining exact IDs without re-deleting completed resources |
| Native successful `azd down` | Confirm ARM accounts, runtime identity, storage, schedules and owned locks absent, plus all owned external entries terminal; retain unrelated and external prerequisites |

The native rows require an authorized disposable environment. Offline fixtures
exercise real source control flow and mutable provider responses, not actual
Azure deletion, replication timing, or irreversible storage/data retention.

## Verification boundaries

`tests/SetupConsent.Tests.ps1` runs the actual planner/apply loop against real
local journals with mocked provider transports. It covers no-op retention,
partial success, pending unknown responses, checkpoint failures, adopted shared
changes, exact Exchange identities, postcheckpoint contradiction/readback failures,
and refusal to retry unresolved operations. A composed fixture passes real fresh
Easy Auth producer receipts into the real cleanup module and verifies both exact
removal and configuration-drift refusal.

`tests/ManagedDownHooks.Tests.ps1` invokes the real predown, postdown, and
postprovision wrappers and their module imports. Mutable provider fixtures cover
default-No and stale approvals, ARM-existence gates, selected-environment guards,
partial cleanup/retry, cascade absence, retained prerequisites, provision-only
receipts, missing-journal recovery, and infrastructure completion before an
optional setup decline.

These checks do not prove Azure/Graph/Exchange propagation, effective permissions,
native `azd down` hook ordering, or live terminal resource absence.

Native qualification must retain the exact source revision and before/after
inventory for all created ARM resources and locks, system-managed identity,
Graph roles, Teams role assignments, subscription/management-group Reader roles,
operator storage-reader assignment, Exchange principal/RBAC, and EasyAuth
application/SP/delegated grants. Verify that the external setup client, security
group, reused objects and unrelated resources remain. Include canceled consent,
partial failure and repeated teardown. An accepted delete response alone is not
proof of completed cleanup, and inaccessible deleted storage is not a claim of
physical data erasure beyond the provider's retention behavior.

## Dedicated-object boundary

Deployment-owned applications, identities and Azure DevOps objects must remain dedicated throughout their lifetime. Do not repurpose, share or concurrently edit them. Cleanup checks the reviewed configuration fields and dependencies; it does not inventory every possible application property or downstream reference and cannot guarantee detection of arbitrary later reuse. The separately administered setup client remains outside this ownership boundary.
