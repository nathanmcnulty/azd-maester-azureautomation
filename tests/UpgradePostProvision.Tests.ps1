BeforeAll {
  $script:repoRoot = Split-Path -Parent $PSScriptRoot
  function Import-UpgradeFixture {
    param([switch]$Wrapper)
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    $scripts = Join-Path $root 'scripts'
    New-Item -ItemType Directory -Path (Join-Path $scripts 'vendor/Azd.MaesterHooks') -Force | Out-Null
    foreach ($name in @('Setup-PostDeploy.ps1', 'Run-AzdPostProvision.ps1', 'Resolve-DeploymentTargets.ps1', 'JobScheduleOwnership.ps1')) {
      Copy-Item (Join-Path $script:repoRoot "scripts/$name") (Join-Path $scripts $name)
    }
    $localContent = "# locally maintained runbook`nWrite-Output 'local'`n"
    [IO.File]::WriteAllText((Join-Path $scripts 'Invoke-MaesterAutomationRunbook.ps1'), $localContent)
    Set-Content (Join-Path $scripts 'vendor/Azd.MaesterHooks/Grant-MaesterGraphPermissions.ps1') @'
param($TenantId, $PrincipalObjectId, $PermissionProfile, $IncludeMailSend)
$global:upgradeFixture.GraphGrantCalls++
'@
    if ($Wrapper) {
      Set-Content (Join-Path $scripts 'Setup-PostDeploy.ps1') @'
param($SubscriptionId, $EnvironmentName, $ResourceGroupName, $PermissionProfile, $TenantId, $SecurityGroupObjectId, $SecurityGroupDisplayName)
$global:upgradeFixture.SetupCalls++
'@
    }
    Set-Content (Join-Path $scripts 'Invoke-RunbookValidation.ps1') @'
param($SubscriptionId, $ResourceGroupName, $AutomationAccountName, $RunbookName, $TenantId, [switch]$PassThru)
$global:upgradeFixture.ValidationCalls++
$global:upgradeFixture.ValidatedAccount = $AutomationAccountName
[pscustomobject]@{ ValidationPassed = $true; JobId = 'only-job'; FinalStatus = 'Completed'; CompletedAt = '2026-10-15T00:00:00Z' }
'@
    $scope = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test'
    $accountId = "$scope/providers/Microsoft.Automation/automationAccounts/aa-exact-output"
    $principal = '33333333-3333-4333-8333-333333333333'
    $jobId = '22222222-2222-4222-8222-222222222222'
    $tags = @{ workload = 'maester'; solution = 'automation-account'; environment = 'test'; managedBy = 'azd' }
    $account = [pscustomobject]@{ id = $accountId; name = 'aa-exact-output'; type = 'Microsoft.Automation/automationAccounts'; tags = $tags; identity = @{ type = 'SystemAssigned'; principalId = $principal } }
    $job = [pscustomobject]@{ id = "$accountId/jobSchedules/$jobId"; name = $jobId; type = 'Microsoft.Automation/automationAccounts/jobSchedules'; properties = @{
      jobScheduleId = $jobId; schedule = @{ name = 'maester-weekly-sunday' }; runbook = @{ name = 'maester-runbook' }
      parameters = @{ IncludeAzure = 'false'; ExistingParameter = 'retained' }; runOn = 'existing-hybrid-worker'
    } }
    $schedule = [pscustomobject]@{ id = "$accountId/schedules/maester-weekly-sunday"; name = 'maester-weekly-sunday'; type = 'Microsoft.Automation/automationAccounts/schedules'; properties = @{ frequency = 'Week'; interval = 2; timeZone = 'Pacific/Auckland'; isEnabled = $false; startTime = '2026-10-20T01:23:00Z' } }
    $runbook = [pscustomobject]@{ id = "$accountId/runbooks/maester-runbook"; name = 'maester-runbook'; type = 'Microsoft.Automation/automationAccounts/runbooks'; properties = @{ state = 'Published'; runbookType = 'PowerShell' } }
    $values = @{
      AZURE_ENV_NAME = 'test'; AZURE_SUBSCRIPTION_ID = '11111111-1111-4111-8111-111111111111'; AZURE_RESOURCE_GROUP = 'rg-test'
      automationAccountName = 'aa-exact-output'; automationPrincipalId = $principal; STORAGE_ACCOUNT_NAME = 'stmaester123'; WEB_APP_ENABLED = 'true'; WEB_APP_NAME = 'app-maester'
      AUTOMATION_JOB_SCHEDULE_ID = $jobId; AUTOMATION_OWNED_ACCOUNT_ID = $accountId; AUTOMATION_OWNED_PRINCIPAL_ID = $principal; AUTOMATION_OWNED_JOB_SCHEDULE_ID = $jobId
      AUTOMATION_EXISTING_RESOURCES = 'true'; AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'true'; AUTOMATION_MI_PRINCIPAL_ID = $principal
      SETUP_EXCHANGE_STATUS = 'configured'; SETUP_TEAMS_STATUS = 'configured'; SETUP_AZURE_STATUS = 'configured'
      EXO_APPROLE_ASSIGNMENT_IDS = 'original-exo'; TEAMS_READER_ROLE_ASSIGNMENT_IDS = 'original-teams'; AZURE_ROLE_ASSIGNMENT_IDS = 'original-azure'
      EXO_SERVICE_PRINCIPAL_DISPLAY_NAME = 'original-display'; EASY_AUTH_ENTRA_APP_OBJECT_ID = 'original-app'; EASY_AUTH_ENTRA_APP_CLIENT_ID = 'original-client'; EASY_AUTH_ENTRA_APP_DISPLAY_NAME = 'original-easyauth'
      INCLUDE_EXCHANGE = 'true'; INCLUDE_TEAMS = 'true'; INCLUDE_AZURE = 'true'; AZURE_RBAC_SCOPES = 'original-scopes'; VALIDATE_RUNBOOK_ON_PROVISION = 'true'
    }
    $global:upgradeFixture = @{
      Root = $root; Scripts = $scripts; Values = $values; Account = $account; Job = $job; Schedule = $schedule; Runbook = $runbook
      JobList = [pscustomobject]@{ value = @($job) }; ScheduleList = [pscustomobject]@{ value = @($schedule) }; RunbookList = [pscustomobject]@{ value = @($runbook) }
      Storage = [pscustomobject]@{ id = "$scope/providers/Microsoft.Storage/storageAccounts/stmaester123"; name = 'stmaester123'; type = 'Microsoft.Storage/storageAccounts'; tags = $tags }
      WebApp = [pscustomobject]@{ id = "$scope/providers/Microsoft.Web/sites/app-maester"; name = 'app-maester'; type = 'Microsoft.Web/sites'; kind = 'app'; tags = $tags; properties = @{ defaultHostName = 'app-maester.azurewebsites.net'; serverFarmId = '' } }
      LocalContent = $localContent; PublishedContent = $localContent; Draft = ''; Calls = [Collections.Generic.List[string]]::new()
      SetupCalls = 0; ValidationCalls = 0; GraphGrantCalls = 0; FailPublication = $false; DisappearOnFinalRead = $false; InventoryReads = 0; ReadbackJob = $null
    }
  }
  # All external commands are mocked, including module import. These tests never
  # contact Azure, Graph, azd, or the shared wizard.
  function az { }
  function azd { }
  function Get-AzCliSubscriptionContext { }
  function ConvertTo-BoolOrDefault { param($Value, $Default) if ($Value) { return $Value -eq 'true' }; return $Default }
  function Invoke-GraphRestRequest { }
  function Connect-MgGraphSilent { }
  function Invoke-MgGraphRequest { }
  function Grant-ServicePrincipalAppRoleAssignment { }
  function Test-DirectoryRoleAssignment { }
  function Test-AzureReaderRoleAssignment { }
  function Invoke-UpgradeSetup {
    & (Join-Path $global:upgradeFixture.Scripts 'Setup-PostDeploy.ps1') -SubscriptionId $global:upgradeFixture.Values.AZURE_SUBSCRIPTION_ID -EnvironmentName test -ResourceGroupName rg-test -TenantId tenant-test
  }
  function Invoke-UpgradeWrapper {
    & (Join-Path $global:upgradeFixture.Scripts 'Run-AzdPostProvision.ps1') -SubscriptionId $global:upgradeFixture.Values.AZURE_SUBSCRIPTION_ID -EnvironmentName test -ResourceGroupName rg-test -TenantId tenant-test
  }
}

Describe 'Existing upgrade postdeployment preservation' {
  BeforeEach {
    $script:savedLocation = Get-Location
    $script:savedEnvironment = @{}
    foreach ($name in @('AZURE_ENV_NAME', 'AUTOMATION_EXISTING_RESOURCES', 'AUTOMATION_UPGRADE_PRESERVE_ACCESS', 'AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION', 'INCLUDE_EXCHANGE', 'INCLUDE_TEAMS', 'INCLUDE_AZURE')) {
      $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
      Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    Import-UpgradeFixture
    Mock Import-Module { }
    Mock Get-AzCliSubscriptionContext { [pscustomobject]@{ tenantId = 'tenant-test' } }
    Mock az { $global:LASTEXITCODE = 0; 'mock-token' }
    Mock azd {
      $global:LASTEXITCODE = 0
      $global:upgradeFixture.Calls.Add("azd $($args -join ' ')")
      if ($args[1] -eq 'get-values') { return ($global:upgradeFixture.Values | ConvertTo-Json -Depth 30 -Compress) }
      if ($args[1] -eq 'set') { $global:upgradeFixture.Values[[string]$args[4]] = [string]$args[5]; return }
      throw "Unexpected azd call: $args"
    }
    Mock Invoke-GraphRestRequest { throw 'Graph access must not run in preservation mode.' }
    Mock Connect-MgGraphSilent { throw 'Graph connection must not run in preservation mode.' }
    Mock Invoke-MgGraphRequest { throw 'Graph mutation must not run in preservation mode.' }
    Mock Grant-ServicePrincipalAppRoleAssignment { throw 'Exchange grant must not run.' }
    Mock Test-DirectoryRoleAssignment { throw 'Teams grant must not run.' }
    Mock Test-AzureReaderRoleAssignment { throw 'Azure grant must not run.' }
    Mock Start-Sleep { }
    Mock Invoke-RestMethod {
      param($Method, $Uri, $Headers, $Body, $ContentType)
      $fixture = $global:upgradeFixture
      $fixture.Calls.Add("$Method $Uri")
      $path = $Uri -replace '\?.*$', ''
      if ($Method -ne 'GET') {
        if ($fixture.FailPublication) { throw 'simulated local publication failure' }
        if ($Method -eq 'PUT' -and $path -like '*/runbooks/maester-runbook/draft/content') { $fixture.Draft = $Body; return }
        if ($Method -eq 'POST' -and $path -like '*/runbooks/maester-runbook/publish') { $fixture.PublishedContent = $fixture.Draft; return }
        if ($Method -eq 'PUT' -and $path -eq "https://management.azure.com$($fixture.Job.id)") { $fixture.JobList = [pscustomobject]@{ value = @($fixture.Job) }; return }
        throw "Unexpected mutation: $Method $Uri"
      }
      if ($path -eq "https://management.azure.com$($fixture.Account.id)") { return $fixture.Account }
      if ($path -eq "https://management.azure.com$($fixture.Storage.id)") { return $fixture.Storage }
      if ($path -eq "https://management.azure.com$($fixture.WebApp.id)") { return $fixture.WebApp }
      if ($path -like '*/jobSchedules') {
        $fixture.InventoryReads++
        if ($fixture.DisappearOnFinalRead -and $fixture.InventoryReads -gt 1) { return [pscustomobject]@{ value = @() } }
        return $fixture.JobList
      }
      if ($path -like '*/schedules') { return $fixture.ScheduleList }
      if ($path -like '*/runbooks') { return $fixture.RunbookList }
      if ($path -eq "https://management.azure.com$($fixture.Job.id)") { if ($null -ne $fixture.ReadbackJob) { return $fixture.ReadbackJob }; return $fixture.Job }
      if ($path -eq "https://management.azure.com$($fixture.Runbook.id)") { return $fixture.Runbook }
      if ($path -like '*/runbooks/maester-runbook/content') { return $fixture.PublishedContent }
      if ($path -like '*/resources') { return [pscustomobject]@{ value = @() } }
      if ($path -like '*/config/authsettingsV2') { return [pscustomobject]@{ properties = @{ identityProviders = @{ azureActiveDirectory = @{ registration = @{ clientId = 'original-client'; openIdIssuer = 'original-issuer' } } } } } }
      throw "Unexpected read: $Uri"
    }
  }
  AfterEach {
    Set-Location $script:savedLocation
    foreach ($name in $script:savedEnvironment.Keys) {
      if ($null -eq $script:savedEnvironment[$name]) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
      else { [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name]) }
    }
    $global:LASTEXITCODE = 0
  }

  It 'does no writes or grants when published local content already matches and retains all receipts and properties' {
    $beforeValues = $global:upgradeFixture.Values | ConvertTo-Json -Depth 30 -Compress
    $beforeJob = $global:upgradeFixture.Job | ConvertTo-Json -Depth 30 -Compress
    $beforeSchedule = $global:upgradeFixture.Schedule | ConvertTo-Json -Depth 30 -Compress
    Invoke-UpgradeSetup
    $global:upgradeFixture.Values | ConvertTo-Json -Depth 30 -Compress | Should -BeExactly $beforeValues
    $global:upgradeFixture.Job | ConvertTo-Json -Depth 30 -Compress | Should -BeExactly $beforeJob
    $global:upgradeFixture.Schedule | ConvertTo-Json -Depth 30 -Compress | Should -BeExactly $beforeSchedule
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
    Should -Invoke Invoke-GraphRestRequest -Times 0 -Exactly
    Should -Invoke Connect-MgGraphSilent -Times 0 -Exactly
    Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly
    Should -Invoke Grant-ServicePrincipalAppRoleAssignment -Times 0 -Exactly
    Should -Invoke Test-DirectoryRoleAssignment -Times 0 -Exactly
    Should -Invoke Test-AzureReaderRoleAssignment -Times 0 -Exactly
    $global:upgradeFixture.GraphGrantCalls | Should -Be 0
  }

  It 'fails closed on runtime-only published/local hash mismatch without any writes or grants' {
    $beforeValues = $global:upgradeFixture.Values | ConvertTo-Json -Depth 30 -Compress
    $global:upgradeFixture.PublishedContent = '# different published runbook'
    { Invoke-UpgradeSetup } | Should -Throw '*SHA-256 mismatch*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
    $global:upgradeFixture.Values | ConvertTo-Json -Depth 30 -Compress | Should -BeExactly $beforeValues
    $global:upgradeFixture.PublishedContent | Should -BeExactly '# different published runbook'
    $global:upgradeFixture.GraphGrantCalls | Should -Be 0
    Should -Invoke Invoke-GraphRestRequest -Times 0 -Exactly
    Should -Invoke Connect-MgGraphSilent -Times 0 -Exactly
    Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly
  }

  It 'publishes changed local content once while the existing association remains GET-only on repeated runs' {
    $global:upgradeFixture.Values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'false'
    $global:upgradeFixture.Values.WEB_APP_ENABLED = 'false'
    Mock Invoke-GraphRestRequest { $null }
    $global:upgradeFixture.PublishedContent = '# older published content'
    Invoke-UpgradeSetup
    Invoke-UpgradeSetup
    @($global:upgradeFixture.Calls | Where-Object { $_ -like 'PUT */draft/content?*' }).Count | Should -Be 1
    @($global:upgradeFixture.Calls | Where-Object { $_ -like 'POST */publish?*' }).Count | Should -Be 1
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) [^|]*/(jobSchedules|schedules)/'
    $global:upgradeFixture.Job.properties.parameters.ExistingParameter | Should -Be 'retained'
    $global:upgradeFixture.Job.properties.runOn | Should -Be 'existing-hybrid-worker'
  }

  It 'checks complete live schedule runbook and association inventories before the first publication write' {
    $global:upgradeFixture.Values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'false'
    $global:upgradeFixture.Values.WEB_APP_ENABLED = 'false'
    Mock Invoke-GraphRestRequest { $null }
    $global:upgradeFixture.PublishedContent = '# old'
    Invoke-UpgradeSetup
    $firstWrite = $global:upgradeFixture.Calls.FindIndex([Predicate[string]]{ param($call) $call -match '^(PUT|POST) |^azd env set' })
    $firstWrite | Should -BeGreaterThan 0
    foreach ($segment in @('jobSchedules', 'schedules', 'runbooks')) {
      @($global:upgradeFixture.Calls.GetRange(0, $firstWrite) | Where-Object { [regex]::IsMatch($_, "^GET .*/$segment\?api-version=", [Text.RegularExpressions.RegexOptions]::IgnoreCase) }).Count | Should -Be 1
    }
  }

  It 'leaves the live association and receipts unchanged when authorized local publication fails' {
    $global:upgradeFixture.Values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'false'
    $global:upgradeFixture.Values.WEB_APP_ENABLED = 'false'
    Mock Invoke-GraphRestRequest { $null }
    $global:upgradeFixture.PublishedContent = '# old'
    $global:upgradeFixture.FailPublication = $true
    { Invoke-UpgradeSetup } | Should -Throw '*simulated local publication failure*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match 'azd env set -e test AUTOMATION_OWNED_'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) [^|]*/(jobSchedules|schedules)/'
  }

  It 'fails before mutation for malformed explicit mode values' -ForEach @('yes', '1', ' true ') {
    $global:upgradeFixture.Values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = $_
    { Invoke-UpgradeSetup } | Should -Throw '*AUTOMATION_UPGRADE_PRESERVE_ACCESS must be true or false*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'fails before mutation for a partial ownership receipt' {
    $global:upgradeFixture.Values.Remove('AUTOMATION_OWNED_PRINCIPAL_ID')
    { Invoke-UpgradeSetup } | Should -Throw '*incomplete*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'fails before mutation when the receipt-bound association disappeared' {
    $global:upgradeFixture.JobList = [pscustomobject]@{ value = @() }
    { Invoke-UpgradeSetup } | Should -Throw '*disappeared*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'does not recreate an association that disappears during publication' {
    $global:upgradeFixture.DisappearOnFinalRead = $true
    { Invoke-UpgradeSetup } | Should -Throw '*disappeared*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) [^|]*/(jobSchedules|schedules)/|azd env set'
  }

  It 'rejects each paginated inventory before any mutation' -ForEach @('JobList', 'ScheduleList', 'RunbookList') {
    $global:upgradeFixture[$_] | Add-Member -NotePropertyName nextLink -NotePropertyValue 'https://management.azure.com/next'
    { Invoke-UpgradeSetup } | Should -Throw '*inventory was incomplete*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'requires verified existing ownership for permission preservation even if an account exists' {
    foreach ($key in @('AUTOMATION_OWNED_ACCOUNT_ID', 'AUTOMATION_OWNED_PRINCIPAL_ID', 'AUTOMATION_OWNED_JOB_SCHEDULE_ID')) { $global:upgradeFixture.Values.Remove($key) }
    $global:upgradeFixture.JobList = [pscustomobject]@{ value = @() }
    { Invoke-UpgradeSetup } | Should -Throw '*requires a verified existing*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'rejects conflicts between process and selected access controls before any mutation' -ForEach @(
    @{ Selected = 'true'; Process = 'false' }, @{ Selected = 'false'; Process = 'true' }
  ) {
    $global:upgradeFixture.Values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = $Selected
    $env:AUTOMATION_UPGRADE_PRESERVE_ACCESS = $Process
    { Invoke-UpgradeSetup } | Should -Throw '*process AUTOMATION_UPGRADE_PRESERVE_ACCESS differs*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'rejects conflicting process and selected preprovision flags' {
    $env:AUTOMATION_EXISTING_RESOURCES = 'false'
    { Invoke-UpgradeSetup } | Should -Throw '*process AUTOMATION_EXISTING_RESOURCES differs*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'rejects stale preprovision freshness flags before any mutation' {
    $global:upgradeFixture.Values.AUTOMATION_EXISTING_RESOURCES = 'false'
    { Invoke-UpgradeSetup } | Should -Throw '*differ from the verified preprovision state*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'permits exact explicit adoption and records only its verified ownership receipt' {
    foreach ($suffix in @('ACCOUNT_ID', 'PRINCIPAL_ID', 'JOB_SCHEDULE_ID')) {
      $global:upgradeFixture.Values["AUTOMATION_ADOPT_$suffix"] = $global:upgradeFixture.Values["AUTOMATION_OWNED_$suffix"]
      $global:upgradeFixture.Values.Remove("AUTOMATION_OWNED_$suffix")
    }
    Invoke-UpgradeSetup
    @($global:upgradeFixture.Calls | Where-Object { $_ -like 'azd env set*' }).Count | Should -Be 3
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |SETUP_.*STATUS|EXO_APPROLE_ASSIGNMENT_IDS|TEAMS_READER_ROLE_ASSIGNMENT_IDS|AZURE_ROLE_ASSIGNMENT_IDS|EASY_AUTH_'
  }

  It 'rejects a missing schedule or runbook before publication' -ForEach @('ScheduleList', 'RunbookList') {
    $global:upgradeFixture[$_] = [pscustomobject]@{ value = @() }
    { Invoke-UpgradeSetup } | Should -Throw '*disappeared*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'rejects an unpublished existing runbook before any writes' {
    $global:upgradeFixture.Runbook.properties.state = 'Edit'
    { Invoke-UpgradeSetup } | Should -Throw '*not published*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'accepts reordered association and parameter keys from the exact readback' {
    $job = $global:upgradeFixture.Job
    $global:upgradeFixture.ReadbackJob = [pscustomobject]@{
      id = $job.id; name = $job.name; type = $job.type
      properties = [ordered]@{
        runOn = $job.properties.runOn
        parameters = [ordered]@{ ExistingParameter = 'retained'; IncludeAzure = 'false' }
        runbook = @{ name = 'maester-runbook' }; schedule = @{ name = 'maester-weekly-sunday' }; jobScheduleId = $job.name
      }
    }
    { Invoke-UpgradeSetup } | Should -Not -Throw
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'rejects a wrong-scope association readback before recording any receipt' {
    $global:upgradeFixture.ReadbackJob = $global:upgradeFixture.Job | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $global:upgradeFixture.ReadbackJob.id = '/subscriptions/other/resourceGroups/other/providers/Microsoft.Automation/automationAccounts/other/jobSchedules/' + $global:upgradeFixture.Job.name
    { Invoke-UpgradeSetup } | Should -Throw '*readback does not match its exact ID*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'rejects real association property changes detected on readback' -ForEach @('parameters', 'runOn') {
    $global:upgradeFixture.ReadbackJob = $global:upgradeFixture.Job | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    if ($_ -eq 'runOn') { $global:upgradeFixture.ReadbackJob.properties.runOn = 'changed-worker' }
    else { $global:upgradeFixture.ReadbackJob.properties.parameters.ExistingParameter = 'changed-parameter' }
    { Invoke-UpgradeSetup } | Should -Throw '*association properties changed*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'retains the first deployment branch that publishes before creating its association' {
    Mock Invoke-GraphRestRequest { $null }
    $global:upgradeFixture.Values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'false'
    $global:upgradeFixture.Values.AUTOMATION_EXISTING_RESOURCES = 'false'
    $global:upgradeFixture.Values.WEB_APP_ENABLED = 'false'
    foreach ($key in @('AUTOMATION_OWNED_ACCOUNT_ID', 'AUTOMATION_OWNED_PRINCIPAL_ID', 'AUTOMATION_OWNED_JOB_SCHEDULE_ID')) { $global:upgradeFixture.Values.Remove($key) }
    $global:upgradeFixture.JobList = [pscustomobject]@{ value = @() }
    Invoke-UpgradeSetup
    @($global:upgradeFixture.Calls | Where-Object { $_ -match '^PUT .*/jobSchedules/' }).Count | Should -Be 1
    $publishIndex = $global:upgradeFixture.Calls.FindIndex([Predicate[string]]{ param($call) $call -match '^POST .*/publish\?' })
    $associationIndex = $global:upgradeFixture.Calls.FindIndex([Predicate[string]]{ param($call) $call -match '^PUT .*/jobSchedules/' })
    $publishIndex | Should -BeGreaterThan 0
    $publishIndex | Should -BeLessThan $associationIndex
    $global:upgradeFixture.Values.AUTOMATION_OWNED_JOB_SCHEDULE_ID | Should -Be $global:upgradeFixture.Job.name
    $global:upgradeFixture.Values.AUTOMATION_EXISTING_RESOURCES | Should -Be 'true'
    Invoke-UpgradeSetup
    @($global:upgradeFixture.Calls | Where-Object { $_ -match '^PUT .*/jobSchedules/' }).Count | Should -Be 1
  }

  It 'starts one explicitly enabled validation and none on the next disabled upgrade' {
    Import-UpgradeFixture -Wrapper
    $global:upgradeFixture.Values.AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION = 'true'
    Invoke-UpgradeWrapper
    $global:upgradeFixture.Values.AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION = 'false'
    Invoke-UpgradeWrapper
    $global:upgradeFixture.SetupCalls | Should -Be 2
    $global:upgradeFixture.ValidationCalls | Should -Be 1
    $global:upgradeFixture.ValidatedAccount | Should -Be 'aa-exact-output'
    Get-Content (Join-Path $global:upgradeFixture.Root 'outputs/test-setup-summary.md') -Raw | Should -Match 'Runbook validation status: Skipped'
    Should -Invoke Invoke-GraphRestRequest -Times 0 -Exactly
  }

  It 'retains the default single validation behavior when the local override is absent' {
    Import-UpgradeFixture -Wrapper
    Invoke-UpgradeWrapper
    $global:upgradeFixture.SetupCalls | Should -Be 1
    $global:upgradeFixture.ValidationCalls | Should -Be 1
  }

  It 'honors an explicit process validation override over the shared wizard flag' {
    Import-UpgradeFixture -Wrapper
    $env:AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION = 'false'
    Invoke-UpgradeWrapper
    $global:upgradeFixture.SetupCalls | Should -Be 1
    $global:upgradeFixture.ValidationCalls | Should -Be 0
  }

  It 'rejects conflicts between selected and process validation controls before setup' -ForEach @(
    @{ Selected = 'true'; Process = 'false' }, @{ Selected = 'false'; Process = 'true' }
  ) {
    Import-UpgradeFixture -Wrapper
    $global:upgradeFixture.Values.AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION = $Selected
    $env:AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION = $Process
    { Invoke-UpgradeWrapper } | Should -Throw '*process AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION differs*'
    $global:upgradeFixture.SetupCalls | Should -Be 0
    $global:upgradeFixture.ValidationCalls | Should -Be 0
  }

  It 'rejects malformed validation override before setup or validation can mutate anything' -ForEach @('yes', '0', ' false ') {
    Import-UpgradeFixture -Wrapper
    $global:upgradeFixture.Values.AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION = $_
    { Invoke-UpgradeWrapper } | Should -Throw '*AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION must be true or false*'
    $global:upgradeFixture.SetupCalls | Should -Be 0
    $global:upgradeFixture.ValidationCalls | Should -Be 0
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }
}
