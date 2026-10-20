# Setup identity and reviewed consent migration

This deployment uses Maester 2.3.0. See [the release upgrade notes](maester-230-upgrade.md) for the assessment permission manifest and runtime package changes.

## Bootstrap the operator client separately

Before setup, an authorized tenant administrator must create and consent a dedicated **single-tenant, tenant-owned public client** application. Its sign-in audience must be `AzureADMyOrg`, with a **Mobile and desktop applications** public-client redirect of `http://localhost`. Require assignment on its enterprise application and assign only designated setup administrators or groups. Review the delegated union returned by `Get-MaesterSetupScopes` for the selected options and grant administrator consent explicitly; registration alone is not consent. Follow the [pinned canonical bootstrap instructions](https://github.com/nathanmcnulty/azd-reference/blob/552ade2f0267e6872bd681f9a1d8a67ac72d055b/docs/maester-consent-flow.md#one-time-authorized-administrator-bootstrap). Do not enable extra authentication flows solely to work around a failed normal browser or broker login. The setup client cannot bootstrap or consent itself. A custom client ID belonging to another tenant, the Microsoft Graph Command Line Tools client, and an unbound account are rejected.

Set `MAESTER_SETUP_CLIENT_ID` to that application ID and `MAESTER_SETUP_ACCOUNT` to the exact operator UPN. Keep the selected `AZURE_TENANT_ID` and subscription explicit. No client secret is used. Operator delegated scopes are separate from the managed identity's application permissions, Exchange RBAC, Teams directory role, Azure Reader assignments, and the web application's delegated consent.

Setup first validates the selected deployment's exact resources and ownership. It then verifies or reuses one Graph session bound to the tenant, custom client, account, cloud, complete selected scope union, and `Process` context scope. Start setup in a fresh `pwsh -NoProfile` process. An inherited non-Process Graph context is refused even with replacement authorization. Calls use the real Graph SDK through `Invoke-GraphRestRequest`; no global `Invoke-MgGraphRequest` replacement is installed. Setup does not silently reconnect or change accounts. Normal browser login is allowed only by `-AllowInteractiveGraphLogin`, or an affirmative answer in `-InteractiveConsent`. Replacing a conflicting Process context also requires explicit `-AllowGraphContextReplacement`.

`Process` selects the SDK's in-memory token cache, but does not completely isolate SDK state. Graph Authentication 2.41.0 still reads/writes a shared authentication-record file and can delete that record during failure cleanup. A fresh process avoids inheriting another session's AuthContext, but does not isolate this on-disk record. The SDK can also internally switch from browser authentication to device code if the browser cannot open; the coordinator does not request that fallback. Do not continue an unexpected device-code prompt. Review this shared-record effect with the operator before sign-in. No private SDK settings, cache deletion, or secret-based fallback are added by setup.

This deployment uses canonical hooks 4.0.1 at the exact source revision recorded in [the component lockfile](../azd-components.lock.json). The separate Graph coordinator remains 1.1.0 at reviewed Reference revision `552ade2f0267e6872bd681f9a1d8a67ac72d055b`. The managed-identity target remains the default; the new explicitly selected federated-application target exists for Azure DevOps and is not enabled by these deployment entrypoints. Offline tests qualify coordinator decisions, not native broker/cache behavior. Canonical CI uses SDK 2.38.0, with a separate exact 2.41.0 compatibility pass.

## Interactive teardown

Run `azd down` in an interactive terminal and omit `--no-prompt`. When external cleanup records remain, hooks 3.1.1 refuses the interactive path in CI, with `AZD_NON_INTERACTIVE=true`, or when stdin is redirected, before removing owned locks or Azure resources. The guard checks actual prompt availability; it does not promise that `--no-prompt` is exposed to shell hooks as an environment signal. `-PlanOnly` remains a read-only preview. If Azure is removed before external cleanup is declined or blocked, receipts remain. Recover in an interactive terminal with the original anchors: `./scripts/Run-AzdPostDown.ps1 -EnvironmentName <original-environment> -TenantId <original-tenant> -SubscriptionId <original-subscription> -InteractiveConsent`. This can select a fresh normal-browser login if needed, then separately asks approval for the fresh cleanup plan. Deliberate noninteractive cleanup remains supported with an already verified Graph `Process` context in that same PowerShell process and a fresh exact `-ApprovedPlanHash`; the parent shell's context is not transferred and the reviewed scope union is unchanged.


## Select assessment and optional capabilities

- The wizard asks for **Full [Y/n]**; Yes or Enter selects Full, No selects Minimal.
- An existing `Extended` setting retains its legacy permission set. It is never reinterpreted as Full.
- Mail requires the separate `IncludeMailSend` switch or `INCLUDE_MAIL_SEND=true`; a recipient alone does not authorize `Mail.Send`.
- Report-setting changes require the separate `IncludeReportSettingsWrite` switch or `INCLUDE_REPORT_SETTINGS_WRITE=true`.
- Capability settings describe desired access. They do not approve any grant or consent expansion.

Hosted managed-identity runners receive only the selected, reviewed application roles and workload access. They do not grant permissions or use the operator setup client.

## Review, then apply

Except for the explicitly selected Automation preserve-access upgrade path described below, a direct `Setup-PostDeploy.ps1` or `Run-AzdPostProvision.ps1` invocation is plan-only unless `-Apply` or `-InteractiveConsent` is supplied. Plan-only setup reads the selected authorities but does not upload runtime files, change applications, grant permissions, or record setup receipts.

For example, in PowerShell after the administrator has bootstrapped the client:

```powershell
$target = @{
    EnvironmentName = '<selected-environment>'
    SubscriptionId = '<selected-subscription-id>'
    TenantId = '<selected-tenant-id>'
    ResourceGroupName = '<deployed-resource-group>'
    PermissionProfile = 'Full'
}
$plan = ./scripts/Setup-PostDeploy.ps1 @target
$plan | ConvertTo-Json -Depth 100
# Review the exact tenant, identities, targets, scopes, configuration, and changes.
./scripts/Setup-PostDeploy.ps1 @target -Apply -ApprovedPlanHash $plan.planHash
```

The plan binds the canonical Graph plan hash and manifest hash, selected client/account, managed identity, storage reader, requested Exchange/Teams/Azure roles, each Azure scope, and the web application's app/group/redirect/settings/delegated-consent changes. Existing grants are preserved. New access is shown by category. No application or security group is selected from ambiguous search results.

Apply rebuilds the plan from fresh reads before the first write. A changed role, target, optional capability, configuration, grant state, or manifest invalidates the old hash. Review the new plan instead of automatically approving it. The Graph grant script independently verifies its own current plan hash before applying missing application roles.

Normal `azd` postprovision uses `-InteractiveConsent`: it displays the plan and asks a default-No approval question before any setup access expansion. It never persists approval for a future version. Noninteractive runs require an existing verified session plus an exact reviewed `-ApprovedPlanHash`; interactive mode in CI fails closed. Permission changes may partially succeed if a later service call fails. Rerun the read-only plan, inspect current state, and approve the remaining exact delta. Never reuse an old hash blindly.

Selected Exchange access requires an installed, reviewed `ExchangeOnlineManagement` module and readable Exchange service-principal/RBAC inventory. Missing modules, denied reads, malformed responses, pagination that cannot establish complete inventory, and ambiguous identities stop access planning. There is no grant-after-failed-read or skip-and-continue fallback.

## Existing Automation upgrades

`AUTOMATION_UPGRADE_PRESERVE_ACCESS=true` retains the previously reviewed runtime-only path. It performs no Graph session initialization, consent planning, grants, or Easy Auth changes. Its existing account/principal/schedule ownership receipts, exact target validation, published/local content checks, and final runtime readbacks remain required. This mode does not opt into Full permissions. Change access only through a separate reviewed setup plan.

## Validation boundary

The canonical Graph application-role apply path reads back each new assignment. Other setup categories retain response-based success without terminal state readback; a successful storage/Azure RBAC, Exchange, Teams, or Easy Auth response is not proof of propagation or effective access. Inspect the resulting workload state and runtime evidence separately.

Repository tests exercise these paths with offline fixtures. They do not create an app, sign in, deploy infrastructure, grant tenant access, send mail, or prove a native Maester assessment. Live bootstrap, consent, workload setup, and deployment validation remain separate authorized operator actions.
