# Automation assessment evidence

`Completed` is a service job state, not proof that Maester ran a healthy assessment.
The maintained runbook now captures Maester 2.3.0 `-PassThru` output and Pester
6.2.0 JUnit evidence before publishing the current report. Policy assertion
failures remain valid findings. Maester execution errors, unclassified runtime
exceptions, failed Pester discovery/blocks, missing core cases, inconsistent
counts, zero discovery, and absent or unrelated reports fail closed.

The health contract is the same pure contract reviewed for the Container adapter
in [PR #51](https://github.com/nathanmcnulty/azd-maester-containerappjob/pull/51),
head `dacae290354121588e1ed6459b71b6d89d2193d5`. It is embedded in the
single Automation runbook because that is the file the existing deployment path
publishes. No sibling runtime module, download, deployment change, or permission
addition is needed. A parity test pins the approved pure function text.

## What is checked

- One Maester result, exact version and sentinel, reconciled per-row counts, no
  Maester Error rows, and every ErrorRecord classified using Pester's exact IDs.
  A Failed or Investigate label alone cannot hide an I/O/access exception.
- Pester JUnit root `errors = 0`, including discovery and BeforeAll/block errors
  absent from ordinary per-test rows. Counts reconcile jointly with Investigate.
  XML is bounded and external entities/DTDs are prohibited.
- Core cases MT.1068 and MT.1069 each ran once from their authored paths, with
  Passed or policy-Failed outcomes. These two cases are a minimal discovery
  contract, not broad test, product, permission-profile, or workload coverage.
- The owned `assessment.html` in the new per-invocation directory is nonempty
  and matches the returned OutputFiles path. There is no recursive newest-HTML
  selection or parsing of HTML to recover missing evidence.
- Archive, latest, and optional Web App publication outcomes are reported
  separately. Archive remains best effort in ordinary execution; validation
  rejects Failed/Disabled archive or latest outcomes. Incomplete Web App
  configuration is never a successful publication.

There is no exception for Minimal-profile execution errors, and no permissions
are added to conceal them. A healthy policy failure is different from a runtime
failure; the existing 23-error Minimal-profile result must remain unqualified.

## Job and source binding

The validator starts one job with a fresh GUID and passes it as `ValidationJobId`.
The runbook reports it as `RequestedJobId`: this is caller correlation, not a
claim about Azure host-private metadata. Scheduled runs need no correlation
parameter and continue through the same health gate.

After service completion, the validator uses these existing ARM read APIs for
that exact job:

- [Job Get Output](https://learn.microsoft.com/en-us/rest/api/automation/job/get-output?view=rest-automation-2023-11-01): `jobs/{jobId}/output`
- [Job Get Runbook Content](https://learn.microsoft.com/en-us/rest/api/automation/job/get-runbook-content?view=rest-automation-2023-11-01): `jobs/{jobId}/runbookContent`

The job's source snapshot must match the local maintained runbook. Hashes use
UTF-8 source text with only initial BOM removal and CRLF-to-LF normalization,
consistent with the existing publication verifier. Trailing whitespace is not
trimmed. There is no fallback to the currently published runbook, which could
have changed after the job started. The verified source digest is returned in
operator-side evidence, not echoed by the runbook as purported proof.

The output API must return plain text containing exactly one complete line
prefixed `MAESTER_ASSESSMENT_RECEIPT_V1:`. Parser admission limits are 1,048,576 characters for output/source text and
16,384 characters for receipt JSON. These checks apply after retrieval; they are
not streaming HTTP download limits. Duplicate markers/keys, array-valued
scalars, extra properties, malformed/stale/mismatched receipts, missing output,
source mismatch, and API read failure cannot pass validation. The validator does
not replay raw output, stream diagnostics, or service exception text.

The receipt contains only timestamps, caller correlation, actual verified module
versions and host identity, health counters/core outcomes, report/JUnit hashes,
and publication status. It contains no test names/descriptions, tenant data,
recipient address, raw ErrorRecords, private reports, or tokens. Maester's
assessment diagnostic streams are suppressed from runbook logs. The private
HTML and JUnit stay separate from the compact receipt.

## Restricted diagnostics for a failed assessment

Invocation or assessment-health failure still fails the job with its original
`assessment.*` error. Before rethrowing, the runbook makes a best-effort attempt
to retain only these current-invocation files in the configured existing export
container:

- `failed/<generated-invocation-guid>/diagnostics.json`
- `failed/<generated-invocation-guid>/pester-junit.xml`, when the fixed current-run
  JUnit path is a nonempty regular file of at most 16 MiB (links are rejected)

The generated GUID is independent of caller correlation, so repeated or scheduled
runs cannot overwrite each other's diagnostics. The JSON includes the validated
`RequestedJobId` when supplied, the original stable failure code, and a bounded
sample of upstream error IDs, exception types, messages, and stack text. It never
serializes complete ErrorRecords, TargetObject, InvocationInfo, exception Data,
Graph/account context, the full Maester result, HTML, or the global error list.

`Invoke-Maester -ErrorVariable` supplies diagnostic evidence only. It also captures
handled policy assertions, skips and optional probes during healthy runs, so its
contents never admit or reject health. ErrorRecord and RuntimeException wrappers
are normalized to scalar fields and deduplicated. Non-control-flow records are
prioritized over Pester assertion/skip/inconclusive control flow, solely for the
private sample. At most 32 entries are written; per-entry limits are 256 characters
for ID/type, 2,048 for message/exception stack, and 4,096 for script stack. The JSON
is capped at 256 KiB UTF-8, with clipping, repeats, unsupported inputs and omissions
reported explicitly. Repeat counts cover retained fingerprints; further repeated
omitted records can be counted as omissions. The upstream ErrorVariable
collection itself is not a streaming-memory-bounded API. A bounded sample may omit the eventual root cause.

These files contain sensitive, untrusted upstream error text and test details.
Messages and stacks are not guaranteed secret-free. Keep them restricted to
explicitly authorized operators; do not automatically copy them to public
reports, issues, chat, or ordinary job logs. Retention follows the existing
archive lifecycle and access policy, with no new container, permission, or public
access change. Review those policies before an authorized native rerun.

Before diagnostic PUTs, the same managed-identity storage token performs one
[Get Container Properties HEAD](https://learn.microsoft.com/en-us/rest/api/storageservices/get-container-properties)
request to the exact configured container. The runbook requires HTTP 200 and an
absent `x-ms-blob-public-access` header. It rejects malformed account/container
names, the dashboard container, and `$web`; it does not follow redirects. This is
a point-in-time anonymous-access check, not proof of network isolation or of
least-privilege RBAC. Externally reconfigured storage must not be assumed private
from its name or the template defaults. A public container or failed/denied check
skips diagnostic uploads. No extra permissions are requested. HEAD and diagnostic
PUTs have fixed connection/operation timeouts, no redirects and no retries.
Token acquisition retains the existing SDK behavior; this does not impose an
overall job-duration bound.

Missing files, extraction/token errors and diagnostic upload failures cannot
replace the original failure. The job stream receives only fixed status labels,
the generated correlation ID and relative blob prefix. This path never publishes
HTML, healthy archive reports, latest pointers, Web App content, or an assessment
success receipt. Successful assessments do not publish failure diagnostics.
Configured upstream inline mail may already have occurred before failure; this
path cannot prevent or retract it. Explicit no-mail qualification remains required.

## Qualification and mail

Maester sends configured email inside `Invoke-Maester`, before returning its
result. A post-return health gate cannot prevent or retract that send. Ordinary
execution preserves this behavior and reports `Mail = UpstreamUnverified` when
configured. Evidence always has `MailDeliveryVerified = false`; no delivery claim
is made.

Use explicit no-mail qualification after independently disabling the existing
mail setting through an authorized workflow:

```powershell
./scripts/Invoke-RunbookValidation.ps1 `
  -SubscriptionId <subId> -TenantId <tenantId> `
  -ResourceGroupName <resourceGroup> -AutomationAccountName <automationAccount> `
  -RequireNoMail -PassThru
```

`RequireNoMail` is passed to the runbook and rejects a resolved MailRecipient,
including the Automation-variable fallback, before invoking Maester. It does not
silently clear or change mail configuration. Successful scope is
`NoMailAssessmentHealthAndPublication`. Without this switch the narrower ordinary
scope is `AssessmentHealthAndPublication`, which does not qualify the mail path.

Optional `-ExpectWebApp` requires a successful Web App write.
`-ExpectExchangeImport` and `-ExpectTeamsImport` require the respective locked
module versions to have actually imported. They verify imports only, not
Exchange/IPPS/Teams authentication or workload test coverage. Evidence always
has `WorkloadCoverageVerified = false`; native connectivity, identity, workload
coverage, delivery and cleanup acceptance remain separate.

## Runtime-only scope and unchanged host policy

`-RuntimeValidationOnly` continues to return before authentication, Automation
variable access, assessment and publication. Its distinct receipt is now checked
by the validator and returned as `RuntimeImportsOnly`; it cannot substitute for
an assessment receipt. Assessment/publication/optional-import expectation flags
are rejected in combination with this helper mode before job creation.

The PR #47 host policy is unchanged: stable Core PowerShell 7.6+ on .NET 10+, or
only case-sensitive `7.6.0-preview.5` on .NET major 10. Other prereleases, suffix
variants, Desktop and unsupported .NET combinations are rejected. The legacy
`AllowRuntimeValidationPreview` flag remains runtime-only and widens nothing.

## Verification boundary

Offline tests run the complete maintained runbook with fixture packages and
mocked transport/authentication boundaries, plus the real validation helper and
its job-output/content reads. Real Pester fixtures exercise assertion, skipped,
runtime, discovery, BeforeAll and AfterAll failures. The real locked Maester/Pester
qualification checks that diagnostic-only capture preserves engine causes and
stacks even when JUnit has only error counts and the emitted error stream is empty.
Complete-runbook fixtures also cover private-container checks, restricted failure
artifacts and extraction/token/upload failures without network access. Parser tests cover adversarial schemas,
source races, current-job binding, freshness and publication failures.

These source tests do not validate the provider's actual output framing,
job-source snapshot representation, native 7.6 host behavior, permissions,
optional workloads, mail delivery, report accessibility or cleanup. A separately
authorized native no-mail rerun and independent exact-tree review remain required
before any main merge. No live Azure authentication, job, deployment, grants,
workflow dispatch or merge was performed to implement this source-only draft.
