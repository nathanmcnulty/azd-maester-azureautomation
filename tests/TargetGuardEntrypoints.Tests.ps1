# Offline integration tests: execute the real entrypoints and their real imported
# vendored helpers. Only process/network boundaries are replaced. In particular,
# neither Get-AzCliSubscriptionContext nor Get-AzCliAccessToken is mocked.
BeforeAll {
  $script:guardRepo = Split-Path -Parent $PSScriptRoot
  $script:guardSub = '11111111-1111-4111-8111-111111111111'
  $script:guardTenant = '22222222-2222-4222-8222-222222222222'
  $script:guardOther = '99999999-9999-4999-8999-999999999999'
  function Invoke-GuardEntrypoint {
    param([string]$Name, [switch]$WithoutTenant, [switch]$RuntimeValidationOnly, [switch]$AllowRuntimeValidationPreview)
    if ($Name -eq 'Run-AzdPreUp.ps1') { & (Join-Path $script:guardRepo "scripts/$Name"); return }
    $parameters = @{ SubscriptionId = $script:guardSub }
    if (-not $WithoutTenant) { $parameters.TenantId = $script:guardTenant }
    if ($Name -ne 'Run-AzdPreProvision.ps1') { $parameters.ResourceGroupName = 'rg-guard' }
    if ($Name -eq 'Invoke-RunbookValidation.ps1') {
      $parameters.AutomationAccountName = 'aa-guard'; $parameters.PassThru = $true
      if ($PSBoundParameters.ContainsKey('AllowRuntimeValidationPreview')) { $parameters.AllowRuntimeValidationPreview = $AllowRuntimeValidationPreview }
      if ($PSBoundParameters.ContainsKey('RuntimeValidationOnly')) { $parameters.RuntimeValidationOnly = $RuntimeValidationOnly }
    } elseif ($Name -ne 'Run-AzdPreProvision.ps1') { $parameters.EnvironmentName = 'guard' }
    & (Join-Path $script:guardRepo "scripts/$Name") @parameters
  }
  function Assert-GuardNoWrites {
    $global:targetGuard.Writes.Count | Should -Be 0
    $global:targetGuard.Connects.Count | Should -Be 0
    $global:targetGuard.Roles | Should -Be 0
    @($global:targetGuard.Cli | Where-Object { $_ -match '^account (set|get-access-token)|^login' }).Count | Should -Be 0
  }
}

Describe 'Actual Automation entrypoints enforce fresh canonical target guards' {
  BeforeEach {
    $script:guardLocation = Get-Location
    $script:guardSavedEnv = @{}
    # Real Set-AzdEnvValue also updates process state; restore every changed key.
    foreach ($variable in Get-ChildItem Env:) { $script:guardSavedEnv[$variable.Name] = $variable.Value }
    foreach ($name in @('AZURE_ENV_NAME', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_LOCATION', 'PERMISSION_PROFILE', 'AUTOMATION_EXISTING_RESOURCES', 'AUTOMATION_UPGRADE_PRESERVE_ACCESS', 'AUTOMATION_ADOPT_SOLUTION_TAG', 'MAIL_RECIPIENT', 'MAESTER_STEP_FAILURE_ACTION', 'PSModulePath')) {
      $script:guardSavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
      Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    $env:AZURE_ENV_NAME = 'guard'
    $env:PSModulePath = $script:guardSavedEnv.PSModulePath
    $env:MAESTER_STEP_FAILURE_ACTION = 'Stop'
    $script:guardSavedFunctions = @{}
    foreach ($name in @('az', 'azd', 'Invoke-RestMethod', 'Start-Sleep', 'Connect-ExchangeOnline', 'New-ManagementRoleAssignment', 'New-ServicePrincipal', 'Invoke-MgGraphRequest', 'Install-Module', 'Read-Host')) {
      $script:guardSavedFunctions[$name] = if (Test-Path "Function:global:$name") { (Get-Item "Function:global:$name").ScriptBlock } else { $null }
    }
    $global:targetGuard = @{
      Metadata = @{ id = "/subscriptions/$script:guardSub"; subscriptionId = $script:guardSub; tenantId = $script:guardTenant; displayName = 'Selected subscription'; state = 'Enabled' }
      # This intentionally disagrees with the selected target and is never changed.
      CachedDefault = @{ id = $script:guardOther; tenantId = $script:guardOther; state = 'Enabled'; isDefault = $true }
      Token = @{ accessToken = 'offline-token'; tenant = $script:guardTenant; subscription = $script:guardSub }
      Values = @{ AZURE_ENV_NAME = 'guard'; AZURE_SUBSCRIPTION_ID = $script:guardSub; AZURE_TENANT_ID = $script:guardTenant; AZURE_RESOURCE_GROUP = 'rg-guard'; AZURE_LOCATION = 'westus2' }
      Cli = [Collections.Generic.List[string]]::new(); Writes = [Collections.Generic.List[string]]::new()
      Headers = [Collections.Generic.List[string]]::new(); Reads = [Collections.Generic.List[string]]::new(); Connects = [Collections.Generic.List[object]]::new()
      JobBodies = [Collections.Generic.List[string]]::new(); JobStatus = 'Completed'; JobException = ''; Roles = 0; MetadataFailure = $false; TokenFailure = $false; AllowValidation = $false; AllowGroupCreate = $false; AllowSetup = $false; GraphGrants = 0; ExoTokenFault = ''; ServicePrincipals = 0
    }
    function global:az {
      $f = $global:targetGuard
      $f.Cli.Add(($args -join ' ')); $global:LASTEXITCODE = 0
      if ($args[0] -eq 'rest' -and $args -contains '--method' -and $args -contains 'get') {
        if ($f.MetadataFailure) { $global:LASTEXITCODE = 1; return }
        return ($f.Metadata | ConvertTo-Json -Compress)
      }
      if ($args[0] -eq 'account' -and $args[1] -in @('show', 'list')) {
        return ($f.CachedDefault | ConvertTo-Json -Compress)
      }
      if ($args[0] -eq 'account' -and $args[1] -eq 'get-access-token') {
        if ($args -contains 'https://outlook.office365.com' -and $f.ExoTokenFault) {
          if ($f.ExoTokenFault -eq 'CLI failure') { $global:LASTEXITCODE = 1; return }
          $response = $f.Token.Clone()
          if ($f.ExoTokenFault -eq 'wrong tenant') { $response.tenant = $f.CachedDefault.tenantId } else { $response.accessToken = '' }
          return ($response | ConvertTo-Json -Compress)
        }
        if ($f.TokenFailure) { $global:LASTEXITCODE = 1; return }
        return ($f.Token | ConvertTo-Json -Compress)
      }
      if ($args[0] -eq 'group' -and $args[1] -eq 'exists') { return 'false' }
      if ($f.AllowGroupCreate -and $args[0] -eq 'group' -and $args[1] -eq 'create') { $f.Writes.Add("az $($args -join ' ')"); return }
      $f.Writes.Add("az $($args -join ' ')")
      throw "Offline tripwire: unexpected Azure CLI call $args"
    }
    function global:azd {
      $global:LASTEXITCODE = 0
      if ($args[0] -eq 'env' -and $args[1] -eq 'get-values') { return ($global:targetGuard.Values | ConvertTo-Json -Compress) }
      if ($global:targetGuard.AllowSetup -and $args[0] -eq 'env' -and $args[1] -eq 'set') {
        $global:targetGuard.Writes.Add("azd $($args -join ' ')")
        $global:targetGuard.Values[[string]$args[4]] = [string]$args[5]; return
      }
      $global:targetGuard.Writes.Add("azd $($args -join ' ')")
      throw "Offline tripwire: unexpected azd call $args"
    }
    function global:Invoke-RestMethod {
      param($Method, $Uri, $Headers, $Body, $ContentType, [switch]$SkipHttpErrorCheck, $StatusCodeVariable)
      $f = $global:targetGuard
      $f.Headers.Add([string]$Headers.Authorization)
      if ($Method -ne 'GET') {
        $f.Writes.Add("$Method $Uri")
        if ($f.AllowSetup) {
          if ($Method -eq 'PUT' -and $Uri -match '/draft/content\?') { $f.Draft = $Body; return }
          if ($Method -eq 'POST' -and $Uri -match '/publish\?') { $f.Published = $f.Draft; return }
          if ($Method -eq 'PUT' -and $Uri -match '/jobSchedules/') { return }
        }
        if ($f.AllowValidation -and $Method -eq 'PUT' -and $Uri -match '/jobs/[^/]+\?') { $f.JobBodies.Add([string]$Body); return @{} }
        throw "Offline mutation tripwire: $Method $Uri"
      }
      $f.Reads.Add([string]$Uri)
      if ($f.AllowSetup) {
        $path = $Uri -replace '\?.*$', ''
        if ($Uri -like 'https://graph.microsoft.com/*') {
          if ($Uri -match '/organization') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = $f.Metadata.tenantId; verifiedDomains = @(@{ isInitial = $true; name = 'guard.onmicrosoft.com' }) }) } }
          if ($Uri -match '/appRoleAssignments$') { return [pscustomobject]@{ value = @(@{ resourceId = 'exchange-resource'; appRoleId = 'dc50a0fb-09a3-484d-be87-e023b12c6440' }) } }
          if ($Uri -match '/servicePrincipals\?') { return [pscustomobject]@{ value = @(@{ id = 'exchange-resource' }) } }
          if ($Uri -match '/servicePrincipals/') { return [pscustomobject]@{ id = $f.Account.identity.principalId; appId = 'app-guard'; displayName = 'Guard identity' } }
          return $null
        }
        if ($path -eq "https://management.azure.com$($f.Account.id)") { return $f.Account }
        if ($path -eq "https://management.azure.com$($f.Storage.id)") { return $f.Storage }
        if ($path -match '/(jobSchedules|schedules|runbooks)$') { return [pscustomobject]@{ value = @() } }
        if ($path -match '/runbooks/maester-runbook/content$') { return $f.Published }
        if ($path -match '/runbooks/maester-runbook$') { return [pscustomobject]@{ properties = @{ state = 'Published' } } }
        if ($path -eq "https://management.azure.com$($f.Job.id)") { return $f.Job }
      }
      if ($f.AllowValidation -and $Uri -match '/jobs/[^/]+/streams\?') { return [pscustomobject]@{ value = @() } }
      if ($f.AllowValidation -and $Uri -match '/jobs/[^/]+\?') { return [pscustomobject]@{ properties = @{ status = $f.JobStatus; exception = $f.JobException } } }
      throw "Offline read tripwire: $Method $Uri"
    }
    function global:Start-Sleep { param($Seconds) }
    function global:Install-Module { throw 'Offline installation tripwire' }
    function global:Read-Host { throw 'Offline interactive authentication tripwire' }
    function global:Connect-ExchangeOnline {
      param($AccessToken, $Organization, $ShowBanner)
      $global:targetGuard.Connects.Add(@{ AccessToken = $AccessToken; Organization = $Organization; ShowBanner = $ShowBanner })
    }
    function global:New-ManagementRoleAssignment { $global:targetGuard.Roles++; throw 'Offline role mutation tripwire' }
  }
  AfterEach {
    Set-Location $script:guardLocation
    Get-Module ExchangeOnlineManagement | Where-Object { $_.Path -like "$TestDrive*" } | Remove-Module -Force
    foreach ($variable in Get-ChildItem Env:) {
      if (-not $script:guardSavedEnv.ContainsKey($variable.Name)) { Remove-Item "Env:$($variable.Name)" }
    }
    foreach ($name in $script:guardSavedEnv.Keys) {
      if ($null -eq $script:guardSavedEnv[$name]) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
      else { [Environment]::SetEnvironmentVariable($name, $script:guardSavedEnv[$name]) }
    }
    foreach ($name in $script:guardSavedFunctions.Keys) {
      if ($null -eq $script:guardSavedFunctions[$name]) { Remove-Item "Function:global:$name" -ErrorAction SilentlyContinue }
      else { Set-Item "Function:global:$name" $script:guardSavedFunctions[$name] }
    }
    Remove-Variable targetGuard -Scope Global -ErrorAction SilentlyContinue
  }

  It '<Entry> blocks <Fault> before publication, jobs, grants, or environment writes' -ForEach @(
    foreach ($entry in @('Setup-PostDeploy.ps1', 'Invoke-RunbookValidation.ps1', 'Run-AzdPostProvision.ps1', 'Run-AzdPreProvision.ps1', 'Run-AzdPreUp.ps1')) {
      foreach ($fault in @('wrong tenant', 'wrong subscription', 'Disabled', 'Warned', 'missing state', 'missing tenant', 'read failure')) {
        @{ Entry = $entry; Fault = $fault }
      }
    }
  ) {
    $f = $global:targetGuard
    switch ($Fault) {
      'wrong tenant' { $f.Metadata.tenantId = $script:guardOther }
      'wrong subscription' { $f.Metadata.subscriptionId = $script:guardOther; $f.Metadata.id = "/subscriptions/$script:guardOther" }
      'missing state' { $f.Metadata.Remove('state') }
      'missing tenant' { $f.Metadata.Remove('tenantId') }
      'read failure' { $f.MetadataFailure = $true }
      default { $f.Metadata.state = $Fault }
    }
    $failure = $null
    try { Invoke-GuardEntrypoint -Name $Entry } catch { $failure = $_ }
    $failure | Should -Not -BeNullOrEmpty
    $failure.Exception.Message | Should -Match 'tenant|subscription|ARM|Enabled'
    $failure.Exception.Message | Should -Not -Match 'tripwire'
    Assert-GuardNoWrites
    @($f.Cli | Where-Object { $_ -match '^rest .*management.azure.com/subscriptions/' }).Count | Should -Be 1
    ($f.Cli -join '|') | Should -Match "--subscription $script:guardSub"
    @($f.Cli | Where-Object { $_ -match '^account (list|show)' }).Count | Should -Be 0
    $f.CachedDefault.state | Should -BeExactly 'Enabled'
    $f.Reads.Count | Should -Be 0
  }

  It '<Entry> requires an independently supplied expected tenant' -ForEach @(
    @{ Entry = 'Setup-PostDeploy.ps1' }, @{ Entry = 'Invoke-RunbookValidation.ps1' }, @{ Entry = 'Run-AzdPostProvision.ps1' }
  ) {
    { Invoke-GuardEntrypoint -Name $Entry -WithoutTenant } | Should -Throw '*TenantId*required*'
    Assert-GuardNoWrites
    $global:targetGuard.Cli.Count | Should -Be 0
  }

  It 'runs the actual direct validation job with a valid explicit target despite an unrelated default' {
    $f = $global:targetGuard; $f.AllowValidation = $true
    $result = Invoke-GuardEntrypoint -Name 'Invoke-RunbookValidation.ps1'
    $result.ValidationPassed | Should -BeTrue
    @($f.Headers | Select-Object -Unique) | Should -Be @('Bearer offline-token')
    $result.SubscriptionId | Should -BeExactly $script:guardSub
    $result.AutomationAccountName | Should -BeExactly 'aa-guard'
    $f.Writes.Count | Should -Be 1
    $f.Writes[0] | Should -Match "^PUT https://management.azure.com/subscriptions/$script:guardSub/resourceGroups/rg-guard/providers/Microsoft.Automation/automationAccounts/aa-guard/jobs/"
    $tokenCalls = @($f.Cli | Where-Object { $_ -match '^account get-access-token ' })
    $tokenCalls.Count | Should -Be 1
    $tokenCalls[0] | Should -Match "--subscription $script:guardSub"
    ($f.Cli -join '|') | Should -Not -Match 'account set|account list|account show|login'
    $f.CachedDefault.id | Should -BeExactly $script:guardOther
  }

  It 'serializes the actual job parameter contract for <Mode>' -ForEach @(@{ Mode = 'default' }, @{ Mode = 'enabled' }, @{ Mode = 'explicit false' }) {
    $f = $global:targetGuard; $f.AllowValidation = $true
    $arguments = @{ Name = 'Invoke-RunbookValidation.ps1' }
    if ($Mode -ne 'default') { $arguments.RuntimeValidationOnly = ($Mode -eq 'enabled') }
    Invoke-GuardEntrypoint @arguments | Out-Null
    $f.JobBodies.Count | Should -Be 1
    $job = $f.JobBodies[0] | ConvertFrom-Json -AsHashtable
    $job.properties.runbook.name | Should -BeExactly 'maester-runbook'
    if ($Mode -eq 'enabled') {
      $job.properties.parameters.Count | Should -Be 1
      $job.properties.parameters.RuntimeValidationOnly | Should -BeOfType ([string])
      $job.properties.parameters.RuntimeValidationOnly | Should -BeExactly 'true'
      ($job.properties.parameters.RuntimeValidationOnly | ConvertFrom-Json) | Should -BeOfType ([bool])
      ($job.properties.parameters.RuntimeValidationOnly | ConvertFrom-Json) | Should -BeTrue
    } else { $job.properties.parameters.Count | Should -Be 0 }
    $f.Writes[0] | Should -Match "^PUT https://management.azure.com/subscriptions/$script:guardSub/resourceGroups/rg-guard/providers/Microsoft.Automation/automationAccounts/aa-guard/jobs/"
    ($f.Cli -join '|') | Should -Match "--subscription $script:guardSub"
    ($f.Cli -join '|') | Should -Not -Match 'account set|login'
  }

  It 'serializes the exact preview opt-in Boolean strings' {
    $f = $global:targetGuard; $f.AllowValidation = $true
    Invoke-GuardEntrypoint -Name 'Invoke-RunbookValidation.ps1' -RuntimeValidationOnly -AllowRuntimeValidationPreview | Out-Null
    $job = $f.JobBodies[0] | ConvertFrom-Json -AsHashtable
    $job.properties.parameters.Count | Should -Be 2
    foreach ($name in 'RuntimeValidationOnly', 'AllowRuntimeValidationPreview') {
      $job.properties.parameters[$name] | Should -BeOfType ([string])
      $job.properties.parameters[$name] | Should -BeExactly 'true'
      ($job.properties.parameters[$name] | ConvertFrom-Json) | Should -BeTrue
    }
  }

  It 'rejects preview opt-in without runtime-only mode before CLI or writes' {
    { Invoke-GuardEntrypoint -Name 'Invoke-RunbookValidation.ps1' -AllowRuntimeValidationPreview } | Should -Throw '*requires RuntimeValidationOnly*'
    Assert-GuardNoWrites
    $global:targetGuard.Cli.Count | Should -Be 0
  }

  It 'omits an explicitly false preview parameter' {
    $f = $global:targetGuard; $f.AllowValidation = $true
    Invoke-GuardEntrypoint -Name 'Invoke-RunbookValidation.ps1' -RuntimeValidationOnly -AllowRuntimeValidationPreview:$false | Out-Null
    $job = $f.JobBodies[0] | ConvertFrom-Json -AsHashtable
    $job.properties.parameters.Count | Should -Be 1
    $job.properties.parameters.ContainsKey('AllowRuntimeValidationPreview') | Should -BeFalse
  }

  It 'preserves service failure reporting in runtime-only mode' {
    $f = $global:targetGuard; $f.AllowValidation = $true
    $f.JobStatus = 'Failed'; $f.JobException = 'locked import failed'
    { Invoke-GuardEntrypoint -Name 'Invoke-RunbookValidation.ps1' -RuntimeValidationOnly } |
      Should -Throw '*Final status: Failed. Exception: locked import failed*'
    $f.JobBodies.Count | Should -Be 1
  }

  It 'still blocks the runtime-only job for an invalid target' {
    $f = $global:targetGuard; $f.AllowValidation = $true; $f.Metadata.state = 'Disabled'
    { Invoke-GuardEntrypoint -Name 'Invoke-RunbookValidation.ps1' -RuntimeValidationOnly } | Should -Throw '*Enabled*'
    Assert-GuardNoWrites
    $f.JobBodies.Count | Should -Be 0
  }

  It 'fails actual validation before job creation when token provenance is <_>' -ForEach @('wrong tenant', 'wrong subscription', 'missing token', 'CLI failure') {
    $f = $global:targetGuard; $f.AllowValidation = $true
    switch ($_) {
      'wrong tenant' { $f.Token.tenant = $script:guardOther }
      'wrong subscription' { $f.Token.subscription = $script:guardOther }
      'missing token' { $f.Token.accessToken = '' }
      'CLI failure' { $f.TokenFailure = $true }
    }
    { Invoke-GuardEntrypoint -Name 'Invoke-RunbookValidation.ps1' } | Should -Throw '*token*'
    $f.Writes.Count | Should -Be 0
    $f.Reads.Count | Should -Be 0
  }



  It 'executes real Setup imports/publication and Exchange branch: <ExchangeMode>' -ForEach @(
    @{ ExchangeMode = 'disabled' }, @{ ExchangeMode = 'valid' }, @{ ExchangeMode = 'wrong tenant' }, @{ ExchangeMode = 'missing token' }, @{ ExchangeMode = 'CLI failure' }
  ) {
    # Retain every real script/module except the external Graph grant boundary.
    $root = Join-Path $TestDrive ('setup-publication-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $root -Force | Out-Null
    Copy-Item (Join-Path $script:guardRepo 'scripts') $root -Recurse
    Set-Content (Join-Path $root 'scripts/vendor/Azd.MaesterHooks/Grant-MaesterGraphPermissions.ps1') @'
param($TenantId, $PrincipalObjectId, $PermissionProfile, $IncludeMailSend)
$global:targetGuard.GraphGrants++
if ($TenantId -ne $global:targetGuard.Metadata.tenantId) { throw 'Wrong Graph grant tenant' }
'@
    $f = $global:targetGuard; $f.AllowSetup = $true
    $exchangeEnabled = $ExchangeMode -ne 'disabled'
    if ($exchangeEnabled) {
      $moduleRoot = Join-Path $root 'modules/ExchangeOnlineManagement'
      New-Item -ItemType Directory $moduleRoot -Force | Out-Null
      Set-Content (Join-Path $moduleRoot 'ExchangeOnlineManagement.psm1') @'
function Connect-ExchangeOnline {
  param($AccessToken, $Organization, $ShowBanner)
  $global:targetGuard.Connects.Add(@{ AccessToken = $AccessToken; Organization = $Organization; ShowBanner = $ShowBanner })
}
function New-ServicePrincipal { param($AppId, $ObjectId, $DisplayName); $global:targetGuard.ServicePrincipals++ }
function New-ManagementRoleAssignment { param($Role, $App, $ErrorAction); $global:targetGuard.Roles++; [pscustomobject]@{ Identity = 'offline-role' } }
Export-ModuleMember -Function *
'@
      $env:PSModulePath = (Join-Path $root 'modules') + [IO.Path]::PathSeparator + $env:PSModulePath
      # Load only the local fixture module, never a real Exchange installation.
      Import-Module (Join-Path $moduleRoot 'ExchangeOnlineManagement.psm1') -Force -Global
      if ($ExchangeMode -ne 'valid') { $f.ExoTokenFault = $ExchangeMode }
    }
    $scope = "/subscriptions/$script:guardSub/resourceGroups/rg-guard"
    $principal = '33333333-3333-4333-8333-333333333333'
    $jobId = '44444444-4444-4444-8444-444444444444'
    $tags = @{ workload = 'maester'; solution = 'automation-account'; environment = 'guard'; managedBy = 'azd' }
    $f.Account = [pscustomobject]@{ id = "$scope/providers/Microsoft.Automation/automationAccounts/aa-guard"; name = 'aa-guard'; type = 'Microsoft.Automation/automationAccounts'; tags = $tags; identity = @{ type = 'SystemAssigned'; principalId = $principal } }
    $f.Storage = [pscustomobject]@{ id = "$scope/providers/Microsoft.Storage/storageAccounts/stguard"; name = 'stguard'; type = 'Microsoft.Storage/storageAccounts'; tags = $tags }
    $f.Job = [pscustomobject]@{ id = "$($f.Account.id)/jobSchedules/$jobId"; properties = @{ jobScheduleId = $jobId; schedule = @{ name = 'maester-weekly-sunday' }; runbook = @{ name = 'maester-runbook' } } }
    $f.Values.automationAccountName = 'aa-guard'; $f.Values.automationPrincipalId = $principal
    $f.Values.STORAGE_ACCOUNT_NAME = 'stguard'; $f.Values.WEB_APP_ENABLED = 'false'
    $f.Values.AUTOMATION_JOB_SCHEDULE_ID = $jobId; $f.Values.AUTOMATION_EXISTING_RESOURCES = 'false'
    $failure = $null
    try {
      & (Join-Path $root 'scripts/Setup-PostDeploy.ps1') -SubscriptionId $script:guardSub -TenantId $script:guardTenant -EnvironmentName guard -ResourceGroupName rg-guard -IncludeExchange:$exchangeEnabled -IncludeTeams:$false -IncludeAzure:$false
    } catch { $failure = $_ }
    if ($exchangeEnabled) {
      $exchangeCalls = @($f.Cli | Where-Object { $_ -match '--resource https://outlook.office365.com' })
      $exchangeCalls.Count | Should -Be 1
      $exchangeCalls[0] | Should -Match "--tenant $script:guardTenant"
      $exchangeCalls[0] | Should -Not -Match '--subscription'
      if ($ExchangeMode -ne 'valid') {
        $failure.Exception.Message | Should -Match 'Exchange Online token acquisition failed'
        $f.Connects.Count | Should -Be 0
        $f.Roles | Should -Be 0
        $f.ServicePrincipals | Should -Be 0
        @($f.Writes | Where-Object { $_ -match '/draft|/publish|/appRoleAssignments|/roleAssignments' }).Count | Should -Be 0
        ($f.Cli -join '|') | Should -Not -Match 'login|account set'
        return
      }
      $f.Connects.Count | Should -Be 1
      $f.Connects[0].Organization | Should -BeExactly 'guard.onmicrosoft.com'
      $f.Connects[0].AccessToken | Should -BeExactly 'offline-token'
      $f.Roles | Should -Be 1
    }
    $failure | Should -BeNullOrEmpty
    $f.GraphGrants | Should -Be 1
    $expectedContent = Get-Content (Join-Path $root 'scripts/Invoke-MaesterAutomationRunbook.ps1') -Raw
    $f.Published | Should -BeExactly $expectedContent
    @($f.Writes | Where-Object { $_ -match '^PUT .*?/draft/content\?' }).Count | Should -Be 1
    @($f.Writes | Where-Object { $_ -match '^POST .*?/publish\?' }).Count | Should -Be 1
    @($f.Writes | Where-Object { $_ -match '^PUT .*?/jobSchedules/' }).Count | Should -Be 1
    @($f.Headers | Select-Object -Unique) | Should -Be @('Bearer offline-token')
    ($f.Cli -join '|') | Should -Not -Match 'account set|account list|account show|login'
    $f.Values.AUTOMATION_OWNED_ACCOUNT_ID | Should -BeExactly $f.Account.id
    $f.CachedDefault.id | Should -BeExactly $script:guardOther
  }

  It 'runs actual preup resource group creation only after fresh explicit target validation' {
    $f = $global:targetGuard; $f.AllowGroupCreate = $true
    Invoke-GuardEntrypoint -Name 'Run-AzdPreUp.ps1'
    $f.Writes.Count | Should -Be 1
    $f.Writes[0] | Should -Match "^az group create --name rg-guard --location westus2 --subscription $script:guardSub"
    $f.Cli[0] | Should -Match '^rest '
    ($f.Cli -join '|') | Should -Not -Match 'account set|account list|account show|login'
    $f.CachedDefault.id | Should -BeExactly $script:guardOther
  }

  It 'captures the real Exchange helper splat with only the intended tenant selector' {
    Import-Module (Join-Path $script:guardRepo 'scripts/vendor/Azd.MaesterHooks/Maester-SetupHelpers.psm1') -Force
    Connect-ExchangeOnlineSilent -TenantId $script:guardTenant -Organization 'guard.onmicrosoft.com'
    $f = $global:targetGuard
    $f.Cli.Count | Should -Be 1
    $f.Cli[0] | Should -Match "--tenant $script:guardTenant"
    $f.Cli[0] | Should -Match '--resource https://outlook.office365.com'
    $f.Cli[0] | Should -Not -Match '--subscription|login'
    $f.Connects.Count | Should -Be 1
    $f.Connects[0].AccessToken | Should -BeExactly 'offline-token'
    $f.Connects[0].Organization | Should -BeExactly 'guard.onmicrosoft.com'
    $f.Connects[0].ShowBanner | Should -BeFalse
  }

  It 'blocks Exchange connection and downstream role assignment on <_> tokens' -ForEach @('wrong tenant', 'missing token', 'CLI failure') {
    Import-Module (Join-Path $script:guardRepo 'scripts/vendor/Azd.MaesterHooks/Maester-SetupHelpers.psm1') -Force
    $f = $global:targetGuard
    switch ($_) {
      'wrong tenant' { $f.Token.tenant = $script:guardOther }
      'missing token' { $f.Token.accessToken = '' }
      'CLI failure' { $f.TokenFailure = $true }
    }
    {
      Connect-ExchangeOnlineSilent -TenantId $script:guardTenant -Organization 'guard.onmicrosoft.com'
      New-ManagementRoleAssignment -Role 'View-Only Configuration'
    } | Should -Throw '*token acquisition failed*'
    $f.Connects.Count | Should -Be 0
    $f.Roles | Should -Be 0
    $f.Writes.Count | Should -Be 0
    ($f.Cli -join '|') | Should -Not -Match 'login|account set'
  }
}
