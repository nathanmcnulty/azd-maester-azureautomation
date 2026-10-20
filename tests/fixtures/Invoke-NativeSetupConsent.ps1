# Run in a fresh process: preserve the production module/import visibility while
# replacing only provider boundaries. No real login, CLI, network or grant runs.
param(
  [Parameter(Mandatory)][string]$ProjectRoot,
  [Parameter(Mandatory)][string]$ResultPath,
  [ValidateSet('Plan', 'Apply')][string]$Mode = 'Plan',
  [string]$ApprovedPlanHash
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Inherited operator options must not expand this offline fixture's scope.
Get-ChildItem Env: | Where-Object Name -Match '^(AZURE_|AUTOMATION_|MAESTER_SETUP_|INCLUDE_|EASY_AUTH_|SECURITY_GROUP_|PERMISSION_PROFILE$)' | Remove-Item
$env:AZURE_ENV_NAME = 'native-consent'
$env:MAESTER_SETUP_ACCOUNT = 'operator@example.test'
$env:MAESTER_SETUP_CLIENT_ID = '99999999-9999-4999-8999-999999999999'
$env:POWERSHELL_TELEMETRY_OPTOUT = '1'
$global:nativeSetup = @{
  Tenant = '11111111-1111-4111-8111-111111111111'; Subscription = '22222222-2222-4222-8222-222222222222'
  Principal = '33333333-3333-4333-8333-333333333333'; Operator = '44444444-4444-4444-8444-444444444444'
  Graph = '55555555-5555-4555-8555-555555555555'; App = '66666666-6666-4666-8666-666666666666'
  Writes = [Collections.Generic.List[string]]::new(); ReadsAfterApproval = [Collections.Generic.List[string]]::new()
  Logins = 0; ClientChecks = 0; ClientChecksAfterApproval = 0; ContextChecksAfterApproval = 0
  Error = ''; ErrorId = ''; ErrorType = ''; ErrorStack = ''; Plan = $null
}
$f = $global:nativeSetup
$group = "/subscriptions/$($f.Subscription)/resourceGroups/rg-native-consent"
$f.Account = [pscustomobject]@{
  id = "$group/providers/Microsoft.Automation/automationAccounts/aa-native-consent"
  name = 'aa-native-consent'; type = 'Microsoft.Automation/automationAccounts'
  identity = @{ type = 'SystemAssigned'; principalId = $f.Principal }
  tags = @{ workload = 'maester'; solution = 'automation-account'; environment = 'native-consent'; managedBy = 'azd' }
}
$f.Storage = [pscustomobject]@{
  id = "$group/providers/Microsoft.Storage/storageAccounts/stnativeconsent"; name = 'stnativeconsent'
  type = 'Microsoft.Storage/storageAccounts'; tags = $f.Account.tags
}
$f.Values = @{
  AZURE_ENV_NAME = 'native-consent'; AZURE_TENANT_ID = $f.Tenant; AZURE_SUBSCRIPTION_ID = $f.Subscription
  AZURE_RESOURCE_GROUP = 'rg-native-consent'; STORAGE_ACCOUNT_NAME = $f.Storage.name; WEB_APP_ENABLED = 'false'
  automationAccountName = $f.Account.name; automationPrincipalId = $f.Principal
  AUTOMATION_JOB_SCHEDULE_ID = '77777777-7777-4777-8777-777777777777'
  AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'false'; AUTOMATION_EXISTING_RESOURCES = 'false'
}
$manifest = Get-Content (Join-Path $ProjectRoot 'scripts/vendor/Azd.MaesterHooks/Maester-GraphPermissions.json') -Raw | ConvertFrom-Json -AsHashtable
$f.Roles = @(foreach ($name in $manifest.profiles.Full) {
  [pscustomobject]@{ id = $manifest.applicationRoles[$name].applicationRoleId; value = $name; isEnabled = $true; allowedMemberTypes = @('Application') }
})

# Seed a valid local infrastructure receipt, so the actual post-approval marker
# write is observable. Do not preload any production module into the process.
$environmentPath = Join-Path $ProjectRoot '.azure/native-consent'
$null = New-Item -ItemType Directory -Path $environmentPath -Force
$f.ReceiptPath = Join-Path $environmentPath 'maester-infrastructure-ownership.json'
$f.JournalPath = Join-Path $environmentPath 'maester-setup-ownership.json'
$infra = Join-Path $ProjectRoot 'infra'
$sourceLines = @(Get-ChildItem $infra -Recurse -File | Where-Object { $_.Extension -eq '.bicep' -or $_.Name -eq 'main.parameters.json' } | Sort-Object FullName | ForEach-Object {
  '{0}:{1}' -f [IO.Path]::GetRelativePath($infra, $_.FullName).Replace('\', '/'), (Get-FileHash $_.FullName).Hash.ToLowerInvariant()
})
$sourceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($sourceLines -join "`n")))).ToLowerInvariant()
@{
  schemaVersion = 1; binding = @{ environmentName = 'native-consent'; solutionName = 'automation-account'; tenantId = $f.Tenant; subscriptionId = $f.Subscription; resourceGroupId = $group }
  state = 'Ready'; ownershipId = '88888888-8888-4888-8888-888888888888'; sourceHash = $sourceHash
  preexistenceStatus = 404; createStatus = 201; createdAt = [DateTimeOffset]::UtcNow.ToString('o')
  resourceIds = @($f.Account.id, $f.Storage.id); lockIds = @(); lockStates = @{}; externalSetupStarted = $false
} | ConvertTo-Json -Depth 8 | Set-Content $f.ReceiptPath
$beforeFiles = @(Get-ChildItem $environmentPath -File | ForEach-Object { "$($_.Name):$((Get-FileHash $_.FullName).Hash)" })

# The real coordinator requires the Graph SDK package. Supply an empty offline
# provider package; its commands are the tripwired functions below, so this test
# needs only PowerShell and Pester and cannot autoload an installed SDK transport.
$providerModules = Join-Path $ProjectRoot 'offline-provider-modules'
$provider = Join-Path $providerModules 'Microsoft.Graph.Authentication/2.30.0'
$null = New-Item -ItemType Directory $provider -Force
Set-Content (Join-Path $provider 'Microsoft.Graph.Authentication.psd1') "@{ ModuleVersion = '2.30.0'; GUID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; FunctionsToExport = @(); CmdletsToExport = @() }"
$env:PSModulePath = "$providerModules$([IO.Path]::PathSeparator)$(Join-Path $PSHOME 'Modules')"

function global:az {
  $f = $global:nativeSetup
  $global:LASTEXITCODE = 0
  if ($args -notcontains $f.Subscription) { throw 'NATIVE_SETUP_UNEXPECTED_CLI_TARGET' }
  if ($args[0] -eq 'rest' -and $args[1] -eq '--method' -and $args[2] -eq 'get' -and
      $args -contains "https://management.azure.com/subscriptions/$($f.Subscription)?api-version=2022-12-01") {
    return (@{ id = "/subscriptions/$($f.Subscription)"; subscriptionId = $f.Subscription; tenantId = $f.Tenant; displayName = 'Offline subscription'; state = 'Enabled' } | ConvertTo-Json -Compress)
  }
  if ($args[0] -eq 'account' -and $args[1] -eq 'get-access-token' -and $args -contains 'https://management.azure.com/') {
    return (@{ accessToken = 'offline-arm-token'; tenant = $f.Tenant; subscription = $f.Subscription } | ConvertTo-Json -Compress)
  }
  $f.Writes.Add("az $($args -join ' ')")
  throw 'NATIVE_SETUP_UNEXPECTED_CLI'
}
function global:azd {
  $global:LASTEXITCODE = 0
  if ($args[0] -eq 'env' -and $args[1] -eq 'get-values') { return ($global:nativeSetup.Values | ConvertTo-Json -Compress) }
  $global:nativeSetup.Writes.Add("azd $($args -join ' ')")
  throw 'NATIVE_SETUP_UNEXPECTED_AZD_WRITE'
}
function global:Get-MgEnvironment { [pscustomobject]@{ Name = 'Global' } }
function global:Get-MgContext {
  if ((Get-Content $global:nativeSetup.ReceiptPath -Raw | ConvertFrom-Json).externalSetupStarted) { $global:nativeSetup.ContextChecksAfterApproval++ }
  [pscustomobject]@{
    TenantId = $global:nativeSetup.Tenant; ClientId = $env:MAESTER_SETUP_CLIENT_ID; Account = $env:MAESTER_SETUP_ACCOUNT
    Environment = 'Global'; AuthType = 'Delegated'; ContextScope = 'Process'
    Scopes = @('Application.Read.All', 'AppRoleAssignment.ReadWrite.All', 'Directory.Read.All')
  }
}
function global:Connect-MgGraph { $global:nativeSetup.Logins++; throw 'NATIVE_SETUP_UNEXPECTED_LOGIN' }
function global:Disconnect-MgGraph { throw 'NATIVE_SETUP_UNEXPECTED_LOGOUT' }
function global:Read-Host { throw 'NATIVE_SETUP_UNEXPECTED_PROMPT' }
function global:Install-Module { throw 'NATIVE_SETUP_UNEXPECTED_INSTALL' }
function global:Invoke-WebRequest { throw 'NATIVE_SETUP_UNEXPECTED_WEB_REQUEST' }
function global:Invoke-MgGraphRequest {
  [CmdletBinding()]
  param($Method, $Uri, $Body, $ContentType, $OutputType)
  $f = $global:nativeSetup
  if ($Method -ne 'GET') {
    $f.Writes.Add("$Method $Uri")
    if ($Method -eq 'POST' -and $Uri -ceq "https://graph.microsoft.com/v1.0/servicePrincipals/$($f.Principal)/appRoleAssignments") {
      throw [InvalidOperationException]::new('NATIVE_SETUP_FIRST_GRAPH_WRITE')
    }
    throw 'NATIVE_SETUP_UNEXPECTED_GRAPH_WRITE'
  }
  if ($Uri -eq '/v1.0/organization?$select=id&$top=1') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = $f.Tenant }) } }
  if ($Uri -like "/v1.0/servicePrincipals?*'$env:MAESTER_SETUP_CLIENT_ID'*") {
    $f.ClientChecks++
    if ((Get-Content $f.ReceiptPath -Raw | ConvertFrom-Json).externalSetupStarted) { $f.ClientChecksAfterApproval++ }
    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'setup-sp'; appId = $env:MAESTER_SETUP_CLIENT_ID; appOwnerOrganizationId = $f.Tenant }) }
  }
  if ($Uri -like "/v1.0/applications?*'$env:MAESTER_SETUP_CLIENT_ID'*") {
    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'setup-app'; appId = $env:MAESTER_SETUP_CLIENT_ID; signInAudience = 'AzureADMyOrg'; publicClient = @{ redirectUris = @('http://localhost') } }) }
  }
  if (([string]$Uri).StartsWith("https://graph.microsoft.com/v1.0/servicePrincipals/$($f.Principal)?", [StringComparison]::Ordinal)) {
    return [pscustomobject]@{ id = $f.Principal; appId = $f.App; displayName = 'Offline identity'; servicePrincipalType = 'ManagedIdentity' }
  }
  if ($Uri -eq "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'") {
    return [pscustomobject]@{ value = @([pscustomobject]@{ id = $f.Graph; appId = '00000003-0000-0000-c000-000000000000'; appRoles = $f.Roles }) }
  }
  if ($Uri -eq "https://graph.microsoft.com/v1.0/servicePrincipals/$($f.Principal)/appRoleAssignments?`$top=999") { return [pscustomobject]@{ value = @() } }
  if ($Uri -eq 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName') { return [pscustomobject]@{ id = $f.Operator; userPrincipalName = $env:MAESTER_SETUP_ACCOUNT } }
  throw "NATIVE_SETUP_UNEXPECTED_GRAPH_READ: $Uri"
}
function global:Invoke-RestMethod {
  [CmdletBinding()]
  param($Method, $Uri, $Headers, $Body, $ContentType)
  $f = $global:nativeSetup
  if ($Method -ne 'GET') { $f.Writes.Add("$Method $Uri"); throw 'NATIVE_SETUP_UNEXPECTED_ARM_WRITE' }
  if ($Headers.Authorization -cne 'Bearer offline-arm-token') { throw 'NATIVE_SETUP_UNEXPECTED_ARM_AUTH' }
  if ((Get-Content $f.ReceiptPath -Raw | ConvertFrom-Json).externalSetupStarted) { $f.ReadsAfterApproval.Add([string]$Uri) }
  $path = ([string]$Uri).Split('?')[0]
  if ($path -ceq "https://management.azure.com$($f.Storage.id)") { return $f.Storage }
  if ($path -ceq "https://management.azure.com$($f.Account.id)") { return $f.Account }
  if ($path -ceq "https://management.azure.com$($f.Account.id)/jobSchedules") { return [pscustomobject]@{ value = @() } }
  if ($path -ceq "https://management.azure.com$($f.Account.id)/runbooks") { return [pscustomobject]@{ value = @() } }
  if ($path -ceq "https://management.azure.com$($f.Account.id)/schedules") {
    return [pscustomobject]@{ value = @([pscustomobject]@{ id = "$($f.Account.id)/schedules/maester-weekly-sunday"; name = 'maester-weekly-sunday'; type = 'Microsoft.Automation/automationAccounts/schedules'; properties = @{ isEnabled = $false } }) }
  }
  if ($Uri -eq "https://management.azure.com$($f.Storage.id)/providers/Microsoft.Authorization/roleAssignments?`$filter=atScope()&api-version=2022-04-01") { return [pscustomobject]@{ value = @() } }
  throw "NATIVE_SETUP_UNEXPECTED_ARM_READ: $Uri"
}

try {
  $parameters = @{
    TenantId = $f.Tenant; SubscriptionId = $f.Subscription; EnvironmentName = 'native-consent'; ResourceGroupName = 'rg-native-consent'
    PermissionProfile = 'Full'; IncludeExchange = $false; IncludeTeams = $false; IncludeAzure = $false
    IncludeMailSend = $false; IncludeReportSettingsWrite = $false
  }
  if ($Mode -eq 'Apply') { $parameters.Apply = $true; $parameters.ApprovedPlanHash = $ApprovedPlanHash }
  $f.Plan = & (Join-Path $ProjectRoot 'scripts/Setup-PostDeploy.ps1') @parameters 6>$null
} catch {
  $f.Error = $_.Exception.Message; $f.ErrorId = $_.FullyQualifiedErrorId; $f.ErrorType = $_.Exception.GetType().FullName; $f.ErrorStack = $_.ScriptStackTrace
} finally {
  $f.Marker = (Get-Content $f.ReceiptPath -Raw | ConvertFrom-Json).externalSetupStarted
  $f.Journal = if (Test-Path $f.JournalPath) { Get-Content $f.JournalPath -Raw | ConvertFrom-Json } else { $null }
  $f.LocalFilesUnchanged = ($beforeFiles -join '|') -ceq (@(Get-ChildItem $environmentPath -File | Sort-Object Name | ForEach-Object { "$($_.Name):$((Get-FileHash $_.FullName).Hash)" }) -join '|')
  $f | ConvertTo-Json -Depth 40 | Set-Content $ResultPath
}
