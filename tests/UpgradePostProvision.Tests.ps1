BeforeAll {
  $script:repoRoot = Split-Path -Parent $PSScriptRoot
  function Import-UpgradeFixture {
    param([switch]$Wrapper)
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    $scripts = Join-Path $root 'scripts'
    New-Item -ItemType Directory -Path (Join-Path $scripts 'vendor/Azd.MaesterHooks') -Force | Out-Null
    foreach ($name in @('Setup-PostDeploy.ps1', 'Run-AzdPostProvision.ps1', 'Resolve-DeploymentTargets.ps1', 'JobScheduleOwnership.ps1', 'PreservationMetadata.ps1', 'Resolve-AutomationStorageTarget.ps1')) {
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
    # JSON-derived service responses retain raw types, optional fields, quotes,
    # newlines and literal azd-style interpolation syntax without replaying them.
    $runbook = @'
{
  "name": "maester-runbook",
  "type": "Microsoft.Automation/automationAccounts/runbooks",
  "location": "westus2",
  "tags": { "Owner": "Custom 'quoted' Δ", "Interpolation": "${SHOULD_STAY_LITERAL}", "Empty": "" },
  "properties": {
    "state": "Published", "runbookType": "PowerShell", "runtimeEnvironment": "PowerShell-74-Maester",
    "description": "Description with 'quotes', \"double quotes\", Δ and a newline\n${SHOULD_STAY_LITERAL}",
    "logProgress": true, "logVerbose": false, "logActivityTrace": 4,
    "publishContentLink": { "uri": "https://example.invalid/never-replay" },
    "draft": { "inEdit": false }, "parameters": { "ExistingParameter": { "type": "String", "isMandatory": false } },
    "outputTypes": ["String"], "creationTime": "2020-01-01T00:00:00Z", "lastModifiedTime": "2020-02-01T00:00:00Z",
    "jobCount": 3, "provisioningState": "Succeeded"
  },
  "etag": "response-only", "systemData": { "createdBy": "response-only" }
}
'@ | ConvertFrom-Json
    $runbook | Add-Member -NotePropertyName id -NotePropertyValue "$accountId/runbooks/maester-runbook"
    $runtime = @'
{"name":"PowerShell-74-Maester","type":"Microsoft.Automation/automationAccounts/runtimeEnvironments","location":"westus2","properties":{"runtime":{"language":"PowerShell","version":"7.4"},"provisioningState":"Succeeded"}}
'@ | ConvertFrom-Json
    $runtime | Add-Member -NotePropertyName id -NotePropertyValue "$accountId/runtimeEnvironments/PowerShell-74-Maester"
    $values = @{
      AZURE_ENV_NAME = 'test'; AZURE_SUBSCRIPTION_ID = '11111111-1111-4111-8111-111111111111'; AZURE_RESOURCE_GROUP = 'rg-test'
      automationAccountName = 'aa-exact-output'; automationPrincipalId = $principal; automationRuntimeEnvironmentName = 'PowerShell-74-Maester'; automationRuntimeEnvironmentVersion = '7.4'; STORAGE_ACCOUNT_NAME = 'stmaester6cykv256tyq6q'; WEB_APP_ENABLED = 'true'; WEB_APP_NAME = 'app-maester-6cykv256tyq6q'
      AUTOMATION_JOB_SCHEDULE_ID = $jobId; AUTOMATION_OWNED_ACCOUNT_ID = $accountId; AUTOMATION_OWNED_PRINCIPAL_ID = $principal; AUTOMATION_OWNED_JOB_SCHEDULE_ID = $jobId
      AUTOMATION_EXISTING_RESOURCES = 'true'; AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'true'; AUTOMATION_MI_PRINCIPAL_ID = $principal
      SETUP_EXCHANGE_STATUS = 'configured'; SETUP_TEAMS_STATUS = 'configured'; SETUP_AZURE_STATUS = 'configured'
      EXO_APPROLE_ASSIGNMENT_IDS = 'original-exo'; TEAMS_READER_ROLE_ASSIGNMENT_IDS = 'original-teams'; AZURE_ROLE_ASSIGNMENT_IDS = 'original-azure'
      EXO_SERVICE_PRINCIPAL_DISPLAY_NAME = 'original-display'; EASY_AUTH_ENTRA_APP_OBJECT_ID = 'original-app'; EASY_AUTH_ENTRA_APP_CLIENT_ID = 'original-client'; EASY_AUTH_ENTRA_APP_DISPLAY_NAME = 'original-easyauth'
      INCLUDE_EXCHANGE = 'true'; INCLUDE_TEAMS = 'true'; INCLUDE_AZURE = 'true'; AZURE_RBAC_SCOPES = 'original-scopes'; VALIDATE_RUNBOOK_ON_PROVISION = 'true'
    }
    $global:upgradeFixture = @{
      Root = $root; Scripts = $scripts; Values = $values; Account = $account; Job = $job; Schedule = $schedule; Runbook = $runbook; Runtime = $runtime
      JobList = [pscustomobject]@{ value = @($job) }; ScheduleList = [pscustomobject]@{ value = @($schedule) }; RunbookList = [pscustomobject]@{ value = @($runbook) }
      Group = [pscustomobject]@{ id = $scope; name = 'rg-test'; type = 'Microsoft.Resources/resourceGroups' }
      Storage = [pscustomobject]@{ id = "$scope/providers/Microsoft.Storage/storageAccounts/stmaester6cykv256tyq6q"; name = 'stmaester6cykv256tyq6q'; type = 'Microsoft.Storage/storageAccounts'; tags = $tags }
      WebApp = [pscustomobject]@{ id = "$scope/providers/Microsoft.Web/sites/app-maester-6cykv256tyq6q"; name = 'app-maester-6cykv256tyq6q'; type = 'Microsoft.Web/sites'; kind = 'app'; tags = $tags; properties = @{ defaultHostName = 'app-maester-6cykv256tyq6q.azurewebsites.net'; serverFarmId = '' } }
      LocalContent = $localContent; PublishedContent = $localContent; Draft = ''; Calls = [Collections.Generic.List[string]]::new()
      RuntimePatchBodies = [Collections.Generic.List[string]]::new(); RuntimePatchAttempts = 0; FailRuntimePatch = ''; AfterRuntimePatch = $null; RuntimeReads = 0; RunbookReads = 0; BeforeRunbookInventory = $null; BeforeRunbookRead = $null; BeforeContentRead = $null; ContentReads = 0
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
  function Set-UpgradeRawJobSchedule {
    # Raw GET/list response shape: no synthetic ARM name or type fields.
    $json = @'
{
  "id": "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-exact-output/jobSchedules/22222222-2222-4222-8222-222222222222",
  "properties": {
    "jobScheduleId": "22222222-2222-4222-8222-222222222222",
    "schedule": { "name": "maester-weekly-sunday" },
    "runbook": { "name": "maester-runbook" },
    "parameters": { "IncludeAzure": "false", "ExistingParameter": "retained" },
    "runOn": "existing-hybrid-worker"
  }
}
'@
    $global:upgradeFixture.Job = $json | ConvertFrom-Json
    $global:upgradeFixture.JobList = [pscustomobject]@{ value = @($global:upgradeFixture.Job) }
    $global:upgradeFixture.ReadbackJob = $json | ConvertFrom-Json
  }
  function Set-UpgradeCustomMetadata {
    $fixture = $global:upgradeFixture
    $oldId = $fixture.Account.id
    $newId = $oldId -replace '/aa-exact-output$', '/aa-test'
    $fixture.Account.id = $newId; $fixture.Account.name = 'aa-test'
    foreach ($item in @($fixture.Job, $fixture.Schedule, $fixture.Runbook, $fixture.Runtime)) { $item.id = $item.id.Replace($oldId, $newId) }
    if ($null -ne $fixture.ReadbackJob) { $fixture.ReadbackJob.id = $fixture.ReadbackJob.id.Replace($oldId, $newId) }
    $fixture.Values.automationAccountName = 'aa-test'
    $fixture.Values.AUTOMATION_OWNED_ACCOUNT_ID = $newId
    $fixture.Values.AUTOMATION_ADOPT_SOLUTION_TAG = 'Reviewed custom deployment'
    $fixture.Account.tags.solution = 'Reviewed custom deployment'
  }
  function Set-UpgradeRuntimeVersion {
    param([string]$Version = '7.4', [switch]$Unbound)
    $fixture = $global:upgradeFixture
    $name = "PowerShell-$($Version.Replace('.', ''))-Maester"
    $fixture.Values.automationRuntimeEnvironmentName = $name
    $fixture.Values.automationRuntimeEnvironmentVersion = $Version
    $fixture.Runtime.id = "$($fixture.Account.id)/runtimeEnvironments/$name"
    $fixture.Runtime.name = $name
    $fixture.Runtime.properties.runtime.version = $Version
    $fixture.Runbook.properties.runtimeEnvironment = if ($Unbound) { 'PowerShell-72-Existing' } else { $name }
  }
  function Assert-UpgradeRuntimePatchOnly {
    $fixture = $global:upgradeFixture
    $fixture.RuntimePatchBodies.Count | Should -Be 1
    $body = $fixture.RuntimePatchBodies[0] | ConvertFrom-Json
    @($body.PSObject.Properties.Name) | Should -Be @('properties')
    @($body.properties.PSObject.Properties.Name) | Should -Be @('runtimeEnvironment')
    $body.properties.runtimeEnvironment | Should -BeExactly $fixture.Values.automationRuntimeEnvironmentName
    ($fixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|DELETE) |azd env set|/draft|/publish\?|/jobs\?|/roleAssignments|graph.microsoft.com'
    $fixture.ValidationCalls | Should -Be 0
    $fixture.GraphGrantCalls | Should -Be 0
    Should -Invoke Invoke-GraphRestRequest -Times 0 -Exactly
    Should -Invoke Connect-MgGraphSilent -Times 0 -Exactly
    Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly
    Should -Invoke Grant-ServicePrincipalAppRoleAssignment -Times 0 -Exactly
    Should -Invoke Test-DirectoryRoleAssignment -Times 0 -Exactly
    Should -Invoke Test-AzureReaderRoleAssignment -Times 0 -Exactly
  }
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
    foreach ($name in @('AZURE_ENV_NAME', 'AUTOMATION_EXISTING_RESOURCES', 'AUTOMATION_UPGRADE_PRESERVE_ACCESS', 'AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION', 'AUTOMATION_ADOPT_SOLUTION_TAG', 'INCLUDE_EXCHANGE', 'INCLUDE_TEAMS', 'INCLUDE_AZURE')) {
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
        if ($Method -eq 'PATCH' -and $path -eq "https://management.azure.com$($fixture.Runbook.id)") {
          $fixture.RuntimePatchAttempts++
          $fixture.RuntimePatchBodies.Add([string]$Body)
          if ($fixture.FailRuntimePatch -eq 'before apply') { throw 'simulated runtime PATCH failure before apply' }
          $patch = $Body | ConvertFrom-Json
          $fixture.Runbook.properties.runtimeEnvironment = $patch.properties.runtimeEnvironment
          if ($fixture.AfterRuntimePatch) { & $fixture.AfterRuntimePatch $fixture }
          if ($fixture.FailRuntimePatch -eq 'after apply') { throw 'simulated runtime PATCH response failure after apply' }
          return ($fixture.Runbook | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        }
        if ($fixture.FailPublication) { throw 'simulated local publication failure' }
        if ($Method -eq 'PUT' -and $path -like '*/runbooks/maester-runbook/draft/content') { $fixture.Draft = $Body; return }
        if ($Method -eq 'POST' -and $path -like '*/runbooks/maester-runbook/publish') { $fixture.PublishedContent = $fixture.Draft; return }
        if ($Method -eq 'PUT' -and $path -eq "https://management.azure.com$($fixture.Job.id)") { $fixture.JobList = [pscustomobject]@{ value = @($fixture.Job) }; return }
        throw "Unexpected mutation: $Method $Uri"
      }
      if ($path -eq "https://management.azure.com$($fixture.Account.id)") { return $fixture.Account }
      if ($path -eq "https://management.azure.com$($fixture.Group.id)") { return $fixture.Group }
      if ($path -eq "https://management.azure.com$($fixture.Storage.id)") { return $fixture.Storage }
      if ($path -eq "https://management.azure.com$($fixture.WebApp.id)") { return $fixture.WebApp }
      if ($path -like '*/jobSchedules') {
        $fixture.InventoryReads++
        if ($fixture.DisappearOnFinalRead -and $fixture.InventoryReads -gt 1) { return [pscustomobject]@{ value = @() } }
        return $fixture.JobList
      }
      if ($path -like '*/schedules') { return $fixture.ScheduleList }
      if ($path -like '*/runbooks') {
        if ($fixture.BeforeRunbookInventory) { & $fixture.BeforeRunbookInventory $fixture }
        return $fixture.RunbookList
      }
      if ($path -eq "https://management.azure.com$($fixture.Job.id)") { if ($null -ne $fixture.ReadbackJob) { return $fixture.ReadbackJob }; return $fixture.Job }
      if ($path -eq "https://management.azure.com$($fixture.Runtime.id)") {
        $fixture.RuntimeReads++
        return ($fixture.Runtime | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
      }
      if ($path -eq "https://management.azure.com$($fixture.Runbook.id)") {
        $fixture.RunbookReads++
        if ($fixture.BeforeRunbookRead) { & $fixture.BeforeRunbookRead $fixture }
        return ($fixture.Runbook | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
      }
      if ($path -like '*/runbooks/maester-runbook/content') {
        $fixture.ContentReads++
        if ($fixture.BeforeContentRead) { & $fixture.BeforeContentRead $fixture }
        return $fixture.PublishedContent
      }
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

  It 'binds existing PowerShell <Version> using only runtime PATCH and skips an already-bound repeat' -ForEach @(
    @{ Version = '7.4'; CustomMetadata = $false }, @{ Version = '7.6'; CustomMetadata = $false },
    @{ Version = '7.4'; CustomMetadata = $true }, @{ Version = '7.6'; CustomMetadata = $true }
  ) {
    Set-UpgradeRawJobSchedule
    if ($CustomMetadata) { Set-UpgradeCustomMetadata }
    Set-UpgradeRuntimeVersion -Version $Version -Unbound
    $fixture = $global:upgradeFixture
    $beforeValues = $fixture.Values | ConvertTo-Json -Depth 30 -Compress
    $beforeJob = $fixture.Job | ConvertTo-Json -Depth 30 -Compress
    $beforeReadback = $fixture.ReadbackJob | ConvertTo-Json -Depth 30 -Compress
    $beforeSchedule = $fixture.Schedule | ConvertTo-Json -Depth 30 -Compress
    $beforeRunbook = $fixture.Runbook | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $beforeRunbook.properties.runtimeEnvironment = $fixture.Values.automationRuntimeEnvironmentName
    $beforeContent = $fixture.PublishedContent

    Invoke-UpgradeSetup
    Invoke-UpgradeSetup

    $fixture.RuntimePatchAttempts | Should -Be 1
    Assert-UpgradeRuntimePatchOnly
    ($fixture.Values | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeValues
    ($fixture.Job | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeJob
    ($fixture.ReadbackJob | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeReadback
    ($fixture.Schedule | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeSchedule
    ($fixture.Runbook | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly ($beforeRunbook | ConvertTo-Json -Depth 30 -Compress)
    $fixture.PublishedContent | Should -BeExactly $beforeContent
    $fixture.Calls | Should -Contain "GET https://management.azure.com$($fixture.Runtime.id)?api-version=2024-10-23"
    $fixture.Calls | Should -Contain "PATCH https://management.azure.com$($fixture.Runbook.id)?api-version=2024-10-23"
    $patchIndex = $fixture.Calls.FindIndex([Predicate[string]]{ param($call) $call -match '^PATCH ' })
    @($fixture.Calls.GetRange(0, $patchIndex) | Where-Object { $_ -like 'GET */runbooks/maester-runbook/content?*' }).Count | Should -BeGreaterThan 0
    @($fixture.Calls.GetRange($patchIndex + 1, $fixture.Calls.Count - $patchIndex - 1) | Where-Object { $_ -like 'GET */jobSchedules/*' }).Count | Should -BeGreaterThan 0
  }

  It 'rejects preexisting Edit state for an unbound runtime without attempting recovery' {
    Set-UpgradeRuntimeVersion -Version '7.6' -Unbound
    $fixture = $global:upgradeFixture
    $fixture.Runbook.properties.state = 'Edit'
    { Invoke-UpgradeSetup } | Should -Throw '*not published*'
    $fixture.RuntimePatchAttempts | Should -Be 0
    ($fixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
    $fixture.PublishedContent | Should -BeExactly $fixture.LocalContent
  }

  It 'rejects the unbound runtime before PATCH when published content does not match locally' {
    Set-UpgradeRuntimeVersion -Version '7.6' -Unbound
    $fixture = $global:upgradeFixture
    $fixture.PublishedContent = '# different local publication'
    { Invoke-UpgradeSetup } | Should -Throw '*SHA-256 mismatch*'
    $fixture.RuntimePatchAttempts | Should -Be 0
    ($fixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'fails after runtime PATCH on changed <Problem>, with no corrective write or receipt update' -ForEach @(
    @{ Problem = 'runbook state' }, @{ Problem = 'published content' }, @{ Problem = 'runtime binding' },
    @{ Problem = 'description' }, @{ Problem = 'tags' }, @{ Problem = 'logging' },
    @{ Problem = 'association parameters' }, @{ Problem = 'association runOn' },
    @{ Problem = 'schedule state' }, @{ Problem = 'schedule timing' }
  ) {
    Set-UpgradeRuntimeVersion -Version '7.6' -Unbound
    $fixture = $global:upgradeFixture
    $beforeValues = $fixture.Values | ConvertTo-Json -Depth 30 -Compress
    $fixture.AfterRuntimePatch = switch ($Problem) {
      'runbook state' { { param($f) $f.Runbook.properties.state = 'Edit' } }
      'published content' { { param($f) $f.PublishedContent = '# changed after PATCH' } }
      'runtime binding' { { param($f) $f.Runbook.properties.runtimeEnvironment = 'PowerShell-72-Existing' } }
      'description' { { param($f) $f.Runbook.properties.description = 'changed after PATCH' } }
      'tags' { { param($f) $f.Runbook.tags.Owner = 'changed after PATCH' } }
      'logging' { { param($f) $f.Runbook.properties.logVerbose = $true } }
      'association parameters' { { param($f) $f.Job.properties.parameters.ExistingParameter = 'changed after PATCH' } }
      'association runOn' { { param($f) $f.Job.properties.runOn = 'changed after PATCH' } }
      'schedule state' { { param($f) $f.Schedule.properties.isEnabled = $true } }
      'schedule timing' { { param($f) $f.Schedule.properties.interval = 1 } }
    }
    { Invoke-UpgradeSetup } | Should -Throw
    Assert-UpgradeRuntimePatchOnly
    $fixture.RuntimePatchAttempts | Should -Be 1
    ($fixture.Values | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeValues
  }

  It 'rejects <Shape> runtime drift appearing only in the final inventory after strict helper verification' -ForEach @(
    @{ Shape = 'another string' }, @{ Shape = 'a one-element array' }
  ) {
    Set-UpgradeRuntimeVersion -Version '7.6' -Unbound
    $fixture = $global:upgradeFixture
    $fixture.BeforeRunbookInventory = if ($Shape -eq 'another string') {
      { param($f) if ($f.InventoryReads -eq 3) { $f.Runbook.properties.runtimeEnvironment = 'PowerShell-72-Existing' } }
    } else {
      { param($f) if ($f.InventoryReads -eq 3) { $f.Runbook.properties.runtimeEnvironment = @('PowerShell-76-Maester') } }
    }
    { Invoke-UpgradeSetup } | Should -Throw '*runtime binding changed during final postdeployment readback*'
    Assert-UpgradeRuntimePatchOnly
    $fixture.RuntimePatchAttempts | Should -Be 1
    $fixture.RunbookReads | Should -BeGreaterOrEqual 3
  }

  It 'does not PATCH after the association changes before runtime binding' {
    Set-UpgradeRuntimeVersion -Version '7.6' -Unbound
    $fixture = $global:upgradeFixture
    $fixture.BeforeRunbookRead = { param($f) $f.Job.properties.runOn = 'changed-before-runtime-patch' }
    { Invoke-UpgradeSetup } | Should -Throw '*association or schedule changed before the runtime PATCH*'
    $fixture.RuntimePatchAttempts | Should -Be 0
    ($fixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'retries a failed runtime PATCH <Failure> without publishing or replaying metadata' -ForEach @(
    @{ Failure = 'before apply'; ExpectedAttempts = 2 }, @{ Failure = 'after apply'; ExpectedAttempts = 1 }
  ) {
    Set-UpgradeRuntimeVersion -Version '7.6' -Unbound
    $fixture = $global:upgradeFixture
    $beforeValues = $fixture.Values | ConvertTo-Json -Depth 30 -Compress
    $beforeJob = $fixture.Job | ConvertTo-Json -Depth 30 -Compress
    $beforeSchedule = $fixture.Schedule | ConvertTo-Json -Depth 30 -Compress
    $fixture.FailRuntimePatch = $Failure
    { Invoke-UpgradeSetup } | Should -Throw '*simulated runtime PATCH*'
    $fixture.RuntimePatchAttempts | Should -Be 1
    $fixture.FailRuntimePatch = ''
    Invoke-UpgradeSetup
    $fixture.RuntimePatchAttempts | Should -Be $ExpectedAttempts
    $fixture.Runbook.properties.runtimeEnvironment | Should -BeExactly 'PowerShell-76-Maester'
    $fixture.Runbook.properties.state | Should -BeExactly 'Published'
    $fixture.PublishedContent | Should -BeExactly $fixture.LocalContent
    ($fixture.Values | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeValues
    ($fixture.Job | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeJob
    ($fixture.Schedule | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeSchedule
    foreach ($json in $fixture.RuntimePatchBodies) {
      $body = $json | ConvertFrom-Json
      @($body.PSObject.Properties.Name) | Should -Be @('properties')
      @($body.properties.PSObject.Properties.Name) | Should -Be @('runtimeEnvironment')
    }
    ($fixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|DELETE) |azd env set|/draft|/publish\?|/jobs\?|/roleAssignments|graph.microsoft.com'
    $fixture.GraphGrantCalls | Should -Be 0
  }

  It 'preserves raw missing-name/type inventory and exact readback through <Path>' -ForEach @(
    @{ Path = 'Setup'; CustomMetadata = $false; Wrapper = $false },
    @{ Path = 'Setup custom-tag MainTarget'; CustomMetadata = $true; Wrapper = $false },
    @{ Path = 'postprovision custom-tag MainTarget'; CustomMetadata = $true; Wrapper = $true }
  ) {
    if ($Wrapper) { Import-UpgradeFixture -Wrapper }
    Set-UpgradeRawJobSchedule
    if ($CustomMetadata) { Set-UpgradeCustomMetadata }
    $fixture = $global:upgradeFixture
    $beforeValues = $fixture.Values | ConvertTo-Json -Depth 30 -Compress
    $beforeJob = $fixture.Job | ConvertTo-Json -Depth 30 -Compress
    $beforeReadback = $fixture.ReadbackJob | ConvertTo-Json -Depth 30 -Compress
    $beforeSchedule = $fixture.Schedule | ConvertTo-Json -Depth 30 -Compress

    if ($Wrapper) { Invoke-UpgradeWrapper }
    else { Invoke-UpgradeSetup }

    ($fixture.Values | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeValues
    ($fixture.Job | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeJob
    ($fixture.ReadbackJob | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeReadback
    ($fixture.Schedule | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeSchedule
    $fixture.Job.PSObject.Properties['name'] | Should -BeNullOrEmpty
    $fixture.Job.PSObject.Properties['type'] | Should -BeNullOrEmpty
    $fixture.Job.properties.parameters.ExistingParameter | Should -BeExactly 'retained'
    $fixture.Job.properties.parameters.IncludeAzure | Should -BeExactly 'false'
    $fixture.Job.properties.runOn | Should -BeExactly 'existing-hybrid-worker'
    if (-not $Wrapper) {
      $fixture.Calls | Should -Contain "GET https://management.azure.com$($fixture.Job.id)?api-version=2023-11-01"
    }
    ($fixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
    $fixture.GraphGrantCalls | Should -Be 0
    Should -Invoke Invoke-GraphRestRequest -Times 0 -Exactly
    Should -Invoke Connect-MgGraphSilent -Times 0 -Exactly
    Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly
    Should -Invoke Grant-ServicePrincipalAppRoleAssignment -Times 0 -Exactly
    Should -Invoke Test-DirectoryRoleAssignment -Times 0 -Exactly
    Should -Invoke Test-AzureReaderRoleAssignment -Times 0 -Exactly
  }

  It 'rejects raw association <Problem> in <Response> without writes or receipt changes' -ForEach @(
    @{ Problem = 'contradictory name'; Response = 'inventory'; CustomMetadata = $false },
    @{ Problem = 'contradictory type'; Response = 'inventory'; CustomMetadata = $false },
    @{ Problem = 'wrong full ID'; Response = 'inventory'; CustomMetadata = $false },
    @{ Problem = 'missing required GUID'; Response = 'inventory'; CustomMetadata = $false },
    @{ Problem = 'replacement GUID'; Response = 'inventory'; CustomMetadata = $false },
    @{ Problem = 'contradictory name'; Response = 'exact readback'; CustomMetadata = $false },
    @{ Problem = 'contradictory type'; Response = 'exact readback'; CustomMetadata = $false },
    @{ Problem = 'wrong full ID'; Response = 'exact readback'; CustomMetadata = $false },
    @{ Problem = 'missing required GUID'; Response = 'exact readback'; CustomMetadata = $false },
    @{ Problem = 'replacement GUID'; Response = 'exact readback'; CustomMetadata = $false },
    @{ Problem = 'contradictory name'; Response = 'custom-tag inventory'; CustomMetadata = $true },
    @{ Problem = 'contradictory type'; Response = 'custom-tag inventory'; CustomMetadata = $true },
    @{ Problem = 'wrong full ID'; Response = 'custom-tag inventory'; CustomMetadata = $true },
    @{ Problem = 'missing required GUID'; Response = 'custom-tag inventory'; CustomMetadata = $true },
    @{ Problem = 'replacement GUID'; Response = 'custom-tag inventory'; CustomMetadata = $true }
  ) {
    Set-UpgradeRawJobSchedule
    if ($CustomMetadata) { Set-UpgradeCustomMetadata }
    $fixture = $global:upgradeFixture
    $beforeValues = $fixture.Values | ConvertTo-Json -Depth 30 -Compress
    $job = if ($Response -eq 'exact readback') { $fixture.ReadbackJob } else { $fixture.Job }
    $replacementId = '44444444-4444-4444-8444-444444444444'
    switch ($Problem) {
      'contradictory name' { $job | Add-Member -NotePropertyName name -NotePropertyValue $replacementId }
      'contradictory type' { $job | Add-Member -NotePropertyName type -NotePropertyValue 'Microsoft.Automation/automationAccounts/schedules' }
      'wrong full ID' { $job.id = $job.id.Replace('/automationAccounts/', '/wrongChildType/') }
      'missing required GUID' { $job.properties.PSObject.Properties.Remove('jobScheduleId') }
      'replacement GUID' {
        $job.id = "$($fixture.Account.id)/jobSchedules/$replacementId"
        $job.properties.jobScheduleId = $replacementId
      }
    }
    $beforeJob = $fixture.Job | ConvertTo-Json -Depth 30 -Compress
    $beforeReadback = $fixture.ReadbackJob | ConvertTo-Json -Depth 30 -Compress

    $failure = $null
    try { Invoke-UpgradeSetup } catch { $failure = $_ }
    $failure | Should -Not -BeNullOrEmpty
    $failure.Exception.Message | Should -Match 'jobSchedule|association'
    ($fixture.Calls -join '|') | Should -Match '/jobSchedules\?api-version='
    if ($Response -eq 'exact readback') {
      $fixture.Calls | Should -Contain "GET https://management.azure.com$($fixture.Job.id)?api-version=2023-11-01"
    }

    ($fixture.Values | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeValues
    ($fixture.Job | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeJob
    ($fixture.ReadbackJob | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeReadback
    ($fixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
    $fixture.GraphGrantCalls | Should -Be 0
    Should -Invoke Invoke-GraphRestRequest -Times 0 -Exactly
    Should -Invoke Connect-MgGraphSilent -Times 0 -Exactly
    Should -Invoke Invoke-MgGraphRequest -Times 0 -Exactly
  }

  It 'still requires <Resource> <Field> metadata when only jobSchedule labels are optional' -ForEach @(
    @{ Resource = 'Schedule'; Field = 'name' }, @{ Resource = 'Schedule'; Field = 'type' },
    @{ Resource = 'Runbook'; Field = 'name' }, @{ Resource = 'Runbook'; Field = 'type' }
  ) {
    Set-UpgradeRawJobSchedule
    $fixture = $global:upgradeFixture
    $beforeValues = $fixture.Values | ConvertTo-Json -Depth 30 -Compress
    $fixture[$Resource].PSObject.Properties.Remove($Field)
    $failure = $null
    try { Invoke-UpgradeSetup } catch { $failure = $_ }
    $failure | Should -Not -BeNullOrEmpty
    $failure.Exception.Message | Should -Match "identity|$Field"
    ($fixture.Calls -join '|') | Should -Match '/jobSchedules\?api-version='
    ($fixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
    ($fixture.Values | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $beforeValues
    $fixture.GraphGrantCalls | Should -Be 0
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

  It 'publishes changed local content before runtime PATCH once while the existing association remains GET-only on repeated runs' {
    Set-UpgradeRuntimeVersion -Version '7.6' -Unbound
    $global:upgradeFixture.Values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'false'
    $global:upgradeFixture.Values.WEB_APP_ENABLED = 'false'
    Mock Invoke-GraphRestRequest { $null }
    $global:upgradeFixture.PublishedContent = '# older published content'
    Invoke-UpgradeSetup
    Invoke-UpgradeSetup
    @($global:upgradeFixture.Calls | Where-Object { $_ -like 'PUT */draft/content?*' }).Count | Should -Be 1
    @($global:upgradeFixture.Calls | Where-Object { $_ -like 'POST */publish?*' }).Count | Should -Be 1
    $global:upgradeFixture.RuntimePatchAttempts | Should -Be 1
    $publishIndex = $global:upgradeFixture.Calls.FindIndex([Predicate[string]]{ param($call) $call -match '^POST .*/publish\?' })
    $patchIndex = $global:upgradeFixture.Calls.FindIndex([Predicate[string]]{ param($call) $call -match '^PATCH .*/runbooks/maester-runbook\?' })
    $publishIndex | Should -BeLessThan $patchIndex
    $global:upgradeFixture.Runbook.properties.runtimeEnvironment | Should -BeExactly 'PowerShell-76-Maester'
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

  It 'preserves explicitly bound custom metadata without rewriting tags variables or receipts' {
    Set-UpgradeCustomMetadata
    $global:upgradeFixture.Values.runtimevariableStorageAccountName = 'external-report-sink'
    $before = $global:upgradeFixture.Values | ConvertTo-Json -Depth 30 -Compress
    Invoke-UpgradeSetup
    ($global:upgradeFixture.Values | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
    $global:upgradeFixture.Account.tags.solution | Should -BeExactly 'Reviewed custom deployment'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'rejects a custom live tag with only the preservation flag and no explicit expected metadata' {
    $global:upgradeFixture.Account.tags.solution = 'Reviewed custom deployment'
    { Invoke-UpgradeSetup } | Should -Throw '*exact subscription*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'rejects explicit custom metadata outside preservation mode' {
    Set-UpgradeCustomMetadata
    $global:upgradeFixture.Values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'false'
    { Invoke-UpgradeSetup } | Should -Throw '*requires AUTOMATION_UPGRADE_PRESERVE_ACCESS=true*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'rejects incomplete custom metadata ownership before any write' {
    Set-UpgradeCustomMetadata
    $global:upgradeFixture.Values.Remove('AUTOMATION_OWNED_PRINCIPAL_ID')
    { Invoke-UpgradeSetup } | Should -Throw '*incomplete*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'rejects structurally valid custom metadata with the wrong live principal' {
    Set-UpgradeCustomMetadata
    $global:upgradeFixture.Values.AUTOMATION_OWNED_PRINCIPAL_ID = '55555555-5555-4555-8555-555555555555'
    { Invoke-UpgradeSetup } | Should -Throw '*receipt does not match the live account*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'rejects custom metadata when its selected live association disappeared or is ambiguous' {
    Set-UpgradeCustomMetadata
    $global:upgradeFixture.JobList = [pscustomobject]@{ value = @() }
    { Invoke-UpgradeSetup } | Should -Throw '*disappeared*'
    $global:upgradeFixture.JobList = [pscustomobject]@{ value = @($global:upgradeFixture.Job, $global:upgradeFixture.Job) }
    { Invoke-UpgradeSetup } | Should -Throw '*More than one*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'retains all non-solution account checks for custom metadata: <Field>' -ForEach @(
    @{ Field = 'environment'; Value = 'other' }, @{ Field = 'workload'; Value = 'other' }, @{ Field = 'managedBy'; Value = 'other' }
  ) {
    Set-UpgradeCustomMetadata
    $global:upgradeFixture.Account.tags = $global:upgradeFixture.Account.tags.Clone()
    $global:upgradeFixture.Account.tags[$Field] = $Value
    { Invoke-UpgradeSetup } | Should -Throw '*scope, tags, and managed identity*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'rejects misleading deployment storage even when the runtime data-sink variable names a real external account' {
    $global:upgradeFixture.Values.STORAGE_ACCOUNT_NAME = 'externalreportsink'
    $global:upgradeFixture.Values.runtimevariableStorageAccountName = 'externalreportsink'
    { Invoke-UpgradeSetup } | Should -Throw '*deterministic main.bicep storage target*'
    ($global:upgradeFixture.Calls -join '|') | Should -Not -Match '\b(PUT|POST|PATCH|DELETE) |azd env set'
  }

  It 'enforces custom metadata live ownership again in postprovision before a validation job' {
    Import-UpgradeFixture -Wrapper
    Set-UpgradeCustomMetadata
    $global:upgradeFixture.Values.AUTOMATION_OWNED_PRINCIPAL_ID = '55555555-5555-4555-8555-555555555555'
    { Invoke-UpgradeWrapper } | Should -Throw '*receipt does not match the live account*'
    $global:upgradeFixture.ValidationCalls | Should -Be 0
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
