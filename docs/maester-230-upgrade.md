# Maester 2.3.0 source upgrade

This change pairs the stable **2.3.0** package and its bundled test suite with the
reviewed, vendored Full/Minimal permission manifest. It does not grant consent,
register applications, deploy resources, send mail, or certify a native job.

## Release and byte provenance

- Official [release 2.3.0](https://github.com/maester365/maester/releases/tag/2.3.0),
  source commit `7413c42d3fcc724dfea94d2726e690ddd364d914`
- [PowerShell Gallery 2.3.0](https://www.powershellgallery.com/packages/Maester/2.3.0)
  `.nupkg` SHA-256 `95F720822D04271F5E15F4665BC017111DC72E17B97E5D0525CB4EC2FF5BD0B0`
- Bundled `maester-tests`: 519 test files and 524 total files; package config
  version `2026.10.06.1`. Every test file matches the release commit byte-for-byte.
  The packaged config updates its release/version fields.
- Package dependencies remain compatible with the existing reviewed Graph
  Authentication 2.41.0 and Pester 6.2.0 pins. Other module pins are unchanged.
- The upstream module manifest still declares PowerShell 5.1 as its own minimum.
  The host deliberately retains its stricter PowerShell 7.6/.NET 10 contract.

No floating `latest`, main-branch tests, `Update-MaesterTests`, or preview package
is introduced. Package verification happens before import. Hashes establish byte
integrity; they are not independent publisher signatures.

## Explicit compatibility changes

The maintained runner selects **exactly** Maester 2.3.0, and the strict assessment
result parser accepts that version only. Old 2.2.0 results, future 2.3.1/3.0.0
results, and preview labels cannot satisfy the new receipt contract. Package,
runner, result fixture and health-gate pins changed together. Version regression
tests were run red against the old source before the change.

The original strict ErrorRecord, JUnit, core-test path/identity, count, report
hash, source identity and current-job receipt checks remain. Policy findings may
be valid assessment outcomes; runtime/permission/engine errors are not silently
converted to compliant findings. HTML existence or job success is insufficient.

`tests/Invoke-Maester230Compatibility.ps1` uses the actual locked Maester 2.3.0 and
Pester 6.2.0, two bundled test wrappers with offline policy adapters, and the
production invocation/configuration/health blocks. It checks:

- A real policy assertion result is accepted, with exactly 1 pass, 1 finding,
  1 explicit skip and 2 visible upstream-default exclusions
- A runtime I/O error, setup failure and missing/skipped core test are rejected
- Actual Pester engine errors remain recorded in JUnit
- Inherited drift input is isolated and restored
- No HTTP, workload authentication, installation or output-message tripwire fires

This is real-package compatibility with synthetic inputs, not an assessment of
all 519 test files against a tenant. The full bundled suite remains installed.
Preview and LongRunning retain upstream opt-in defaults; AD needs explicit host
connection. No exclusion is based on a permission-error string.

## Permissions and coverage

The vendored `Maester-GraphPermissions.json` defines Full27, unchanged Minimal8,
and explicit legacy Extended19. Full uses the 25 release-matched read roles plus
Policy.Read.DeviceConfiguration and Sites.Read.All, supported by the actual
application-authenticated endpoints. Sites.Read.All also permits reading
content across all site collections; its broader consequence is in the consent
plan metadata and must be reviewed. Mail.Send and report-privacy writes remain
separate capabilities.

Graph app roles do not authorize Exchange, Teams, Azure or other workloads by
themselves. Full is a reviewed stable Graph baseline, not a guarantee every test
runs. Licenses, API support, service connections, report privacy and the explicit
unverified API dependencies in the manifest remain coverage limits. Choosing
Minimal retains the suite and visible gaps. Existing grants are not revoked.
Grant readback alone does not prove refreshed managed-identity tokens.

One explicit gap is `GET directory/onPremisesSynchronization`: Microsoft's
[v1.0](https://learn.microsoft.com/en-us/graph/api/onpremisesdirectorysynchronization-get?view=graph-rest-1.0)
and [beta](https://learn.microsoft.com/en-us/graph/api/onpremisesdirectorysynchronization-get?view=graph-rest-beta)
contracts mark application access unsupported, despite the upstream application
read role existing. Stable Maester soft/hard-matching and object-identifier
checks use those endpoints. The baseline role remains; app-only support remains
unverified. Existing report-privacy write grants can also enable upstream MOERA
setting changes even when the selected profile adds no new write role.

## Native acceptance and module maintenance

Native validation remains a separate, explicitly authorized gate: inspect actual
host/module receipts, effective workload permissions, full assessment accounting,
per-workload gaps, report delivery/access and retention/rollback. Existing 2.2.0
native receipts remain historical evidence and have not been relabeled as 2.3.0.

The later PowerShell-module maintenance proposal is to add a source-only updater
that checks official stable Gallery versions, downloads exact package bytes,
refreshes provenance, reviews API/permission deltas, and opens a draft with full
compatibility tests. It must never silently update runtime permissions, grant
consent, deploy, or treat Dependabot as covering PowerShell Gallery packages.
That automation is not implemented by this change.

### Automation invocation boundary

Actual-package qualification reproduced a false failure in the earlier
`-ErrorVariable` capture: PowerShell accumulated errors handled inside Maester
and Pester, including ordinary assertions, skips and optional-service probes.
The runner now captures the invocation's emitted error stream as ErrorRecord
objects, separately from its success output. Any emitted error still fails the
run, including a nonterminating error followed by an otherwise valid result.
Terminating exceptions fail as before. The result is invoked once and retained
without coercion; the strict per-test and JUnit gates still reject runtime errors.

This is a stream-boundary correction, not an error-type/message allowlist.
`MaesterInvocationBoundary.Tests.ps1` covers emitted, terminating and success-
stream ErrorRecords, caught assertions/probes, and single-result preservation.
The reviewed health functions' original hashes remain tested after normalizing
only the independently tested version pin from 2.3.0 to 2.2.0.

The infrastructure package URI/hash, runbook's independently enforced lock, and
unscheduled seed source/hash advance together. The seed is still not attached
to a schedule; existing preservation and publication safeguards are unchanged.
