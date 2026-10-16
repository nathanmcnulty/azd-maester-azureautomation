# Offline contract tests. Compiled ARM checks verify emitted request shapes and
# conditions, not Azure provider behavior or a live deployed-state preservation.
BeforeAll {
  . (Join-Path $PSScriptRoot '../scripts/JobScheduleOwnership.ps1')
  $script:upgradeAccountId = '/subscriptions/sub-test/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-test'
  $script:upgradePrincipalId = '11111111-1111-1111-1111-111111111111'
  $script:upgradeJobId = '22222222-2222-2222-2222-222222222222'

  function New-UpgradeFixture {
    $account = [pscustomobject]@{
      id = $script:upgradeAccountId; name = 'aa-test'; type = 'Microsoft.Automation/automationAccounts'
      identity = @{ type = 'SystemAssigned'; principalId = $script:upgradePrincipalId }
      tags = @{ workload = 'maester'; solution = 'automation-account'; environment = 'test'; managedBy = 'azd' }
    }
    $job = [pscustomobject]@{
      id = "$script:upgradeAccountId/jobSchedules/$script:upgradeJobId"; name = $script:upgradeJobId
      type = 'Microsoft.Automation/automationAccounts/jobSchedules'
      properties = @{
        jobScheduleId = $script:upgradeJobId; schedule = @{ name = 'maester-weekly-sunday' }
        runbook = @{ name = 'maester-runbook' }; parameters = @{ TenantId = 'tenant-test'; Custom = 'keep me' }; runOn = 'hybrid-production'
      }
    }
    $schedule = [pscustomobject]@{
      id = "$script:upgradeAccountId/schedules/maester-weekly-sunday"; name = 'maester-weekly-sunday'
      type = 'Microsoft.Automation/automationAccounts/schedules'
      properties = @{
        startTime = '2026-10-18T10:34:00Z'; expiryTime = '2099-12-31T23:59:00Z'; interval = 1
        frequency = 'Week'; timeZone = 'UTC'; advancedSchedule = @{ weekDays = @('Sunday') }; isEnabled = $true
      }
    }
    $runbook = [pscustomobject]@{
      id = "$script:upgradeAccountId/runbooks/maester-runbook"; name = 'maester-runbook'
      type = 'Microsoft.Automation/automationAccounts/runbooks'
      properties = @{ state = 'Published'; runbookType = 'PowerShell'; logProgress = $false; logVerbose = $true; description = 'User-maintained runbook' }
    }
    $otherJob = [pscustomobject]@{
      id = "$script:upgradeAccountId/jobSchedules/33333333-3333-3333-3333-333333333333"
      name = '33333333-3333-3333-3333-333333333333'; type = 'Microsoft.Automation/automationAccounts/jobSchedules'
      properties = @{ jobScheduleId = '33333333-3333-3333-3333-333333333333'; schedule = @{ name = 'unrelated-daily' }; runbook = @{ name = 'other' }; runOn = 'other-worker'; parameters = @{ Custom = 'unrelated' } }
    }
    $otherSchedule = [pscustomobject]@{
      id = "$script:upgradeAccountId/schedules/unrelated-daily"; name = 'unrelated-daily'
      type = 'Microsoft.Automation/automationAccounts/schedules'; properties = @{ frequency = 'Day'; interval = 3; isEnabled = $false }
    }
    @{
      Account = $account; JobSchedules = @($otherJob, $job); Schedules = @($otherSchedule, $schedule); Runbooks = @($runbook)
      Ownership = [pscustomobject]@{ JobScheduleId = $script:upgradeJobId; OwnedJobScheduleId = $script:upgradeJobId }
      Job = $job; Schedule = $schedule; Runbook = $runbook
    }
  }

  function Assert-UpgradeFixture {
    param([hashtable]$Fixture, [switch]$RequireExisting)
    Assert-MaesterExistingAutomationResources -ExpectedAccountId $script:upgradeAccountId -Account $Fixture.Account `
      -JobSchedules $Fixture.JobSchedules -Schedules $Fixture.Schedules -Runbooks $Fixture.Runbooks `
      -Ownership $Fixture.Ownership -RequireExisting:$RequireExisting
  }

  function New-UpgradePreProvisionScenario {
    $fixture = New-UpgradeFixture
    @{
      Values = @{
        AZURE_ENV_NAME = 'test'; AZURE_SUBSCRIPTION_ID = 'sub-test'; AZURE_TENANT_ID = 'tenant-test'
        AZURE_RESOURCE_GROUP = 'rg-test'; AZURE_LOCATION = 'westus'
        AUTOMATION_OWNED_ACCOUNT_ID = $script:upgradeAccountId; AUTOMATION_OWNED_PRINCIPAL_ID = $script:upgradePrincipalId
        AUTOMATION_OWNED_JOB_SCHEDULE_ID = $script:upgradeJobId
      }
      Account = $fixture.Account
      Responses = @{
        accounts = [pscustomobject]@{ value = @($fixture.Account) }; jobSchedules = [pscustomobject]@{ value = $fixture.JobSchedules }
        schedules = [pscustomobject]@{ value = $fixture.Schedules }; runbooks = [pscustomobject]@{ value = $fixture.Runbooks }
      }
      FailKind = ''; RawKind = ''; RawResponse = ''; GroupExists = 'true'; ExtraResources = @{}
    }
  }

  function Invoke-UpgradePreProvision {
    param([hashtable]$Scenario)
    $names = @('AZURE_ENV_NAME', 'AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_LOCATION')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
      $env:AZURE_ENV_NAME = 'test'; $env:AZURE_SUBSCRIPTION_ID = 'sub-test'
      $env:AZURE_TENANT_ID = 'tenant-test'; $env:AZURE_LOCATION = 'westus'
      $global:maesterUpgradeScenario = $Scenario
      $global:maesterUpgradeCalls = [Collections.Generic.List[string]]::new()
      function Import-Module { param([string]$Name, [switch]$Force) }
      function Invoke-MaesterPreProvision { param($SolutionName, $SubscriptionId, $TenantId, $Location) }
      function azd {
        $global:maesterUpgradeCalls.Add("azd $($args -join ' ')")
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'env' -and $args[1] -eq 'get-values') { return ($global:maesterUpgradeScenario.Values | ConvertTo-Json -Compress) }
        if ($args[0] -eq 'env' -and $args[1] -eq 'set') { return }
        throw "Unexpected azd call: $($args -join ' ')"
      }
      function az {
        $command = $args -join ' '
        $global:maesterUpgradeCalls.Add("az $command")
        $global:LASTEXITCODE = 0
        if ($command -like 'group exists *') { return $global:maesterUpgradeScenario.GroupExists }
        if ($command -like 'automation account list *') { return '[]' }
        if ($command -notlike 'rest --method GET *') { throw "Unexpected Azure call: $command" }
        foreach ($id in $global:maesterUpgradeScenario.ExtraResources.Keys) {
          if ($command.Contains("$id`?")) { return ($global:maesterUpgradeScenario.ExtraResources[$id] | ConvertTo-Json -Depth 20 -Compress) }
        }
        if ($command -like '*/runbooks/maester-runbook/content?*') {
          $outputPath = $args[([array]::IndexOf($args, '--output-file') + 1)]
          [IO.File]::WriteAllText($outputPath, (Get-Content (Join-Path $PSScriptRoot '../scripts/Invoke-MaesterAutomationRunbook.ps1') -Raw))
          return
        }
        $kind = if ($command -match '/(jobSchedules|schedules|runbooks)\?') { $Matches[1] }
          elseif ($command -match '/automationAccounts\?') { 'accounts' } else { 'account' }
        if ($global:maesterUpgradeScenario.FailKind -eq $kind) { $global:LASTEXITCODE = 1; return '' }
        if ($global:maesterUpgradeScenario.RawKind -eq $kind) { return $global:maesterUpgradeScenario.RawResponse }
        $response = if ($kind -eq 'account') { $global:maesterUpgradeScenario.Account } else { $global:maesterUpgradeScenario.Responses[$kind] }
        return ($response | ConvertTo-Json -Depth 20 -Compress)
      }
      & (Join-Path $PSScriptRoot '../scripts/Run-AzdPreProvision.ps1')
    }
    finally {
      foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
      $global:LASTEXITCODE = 0
      Remove-Variable maesterUpgradeScenario -Scope Global -ErrorAction SilentlyContinue
    }
  }
}

Describe 'Upgrade option and complete-inventory validation' {
  It 'parses only explicit booleans and uses the requested empty default' {
    Get-MaesterUpgradeBoolean -Value 'true' -Name 'TEST_OPTION' | Should -BeTrue
    Get-MaesterUpgradeBoolean -Value 'FALSE' -Name 'TEST_OPTION' | Should -BeFalse
    Get-MaesterUpgradeBoolean -Value '' -Name 'TEST_OPTION' | Should -BeFalse
    Get-MaesterUpgradeBoolean -Value ' ' -Name 'TEST_OPTION' -Default $true | Should -BeTrue
  }

  It 'rejects a non-boolean option <Value>' -ForEach @(
    @{ Value = '1' }, @{ Value = 'yes' }, @{ Value = ' true ' }, @{ Value = 'on' }
  ) {
    { Get-MaesterUpgradeBoolean -Value $Value -Name 'TEST_OPTION' } | Should -Throw '*TEST_OPTION must be true or false*'
  }

  It 'accepts a complete empty or populated array envelope' {
    { Assert-MaesterCompleteInventory -Response ([pscustomobject]@{ value = @() }) -Name 'schedules' } | Should -Not -Throw
    { Assert-MaesterCompleteInventory -Response ([pscustomobject]@{ value = @([pscustomobject]@{ name = 'one' }); nextLink = '' }) -Name 'runbooks' } | Should -Not -Throw
  }

  It 'rejects <Label> inventory envelopes' -ForEach @(
    @{ Label = 'null'; Response = $null }, @{ Label = 'missing-value'; Response = [pscustomobject]@{ count = 0 } }
    @{ Label = 'null-value'; Response = [pscustomobject]@{ value = $null } }
    @{ Label = 'scalar-value'; Response = [pscustomobject]@{ value = 'not-an-array' } }
    @{ Label = 'object-value'; Response = [pscustomobject]@{ value = [pscustomobject]@{ name = 'one' } } }
    @{ Label = 'paged'; Response = [pscustomobject]@{ value = @(); nextLink = 'https://management.azure.com/next' } }
    @{ Label = 'null-record'; Response = [pscustomobject]@{ value = @($null) } }
  ) {
    { Assert-MaesterCompleteInventory -Response $Response -Name 'schedules' } | Should -Throw '*inventory was incomplete*'
  }
}

Describe 'Exact existing Automation preservation binding' {
  It 'returns the same enabled Sunday 10:34 UTC schedule, runbook, association and unrelated resources unchanged' {
    $fixture = New-UpgradeFixture
    $before = $fixture | ConvertTo-Json -Depth 30 -Compress
    $result = Assert-UpgradeFixture -Fixture $fixture -RequireExisting
    $result.Existing | Should -BeTrue
    [object]::ReferenceEquals($result.Schedule, $fixture.Schedule) | Should -BeTrue
    [object]::ReferenceEquals($result.JobSchedule, $fixture.Job) | Should -BeTrue
    [object]::ReferenceEquals($result.Runbook, $fixture.Runbook) | Should -BeTrue
    $result.Schedule.properties.startTime | Should -Be '2026-10-18T10:34:00Z'
    $result.Schedule.properties.advancedSchedule.weekDays | Should -Be @('Sunday')
    $result.JobSchedule.properties.parameters.Custom | Should -Be 'keep me'
    $result.JobSchedule.properties.runOn | Should -Be 'hybrid-production'
    ($fixture | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
  }

  It 'preserves a <Label> schedule without normalization' -ForEach @(
    @{ Label = 'disabled'; Changes = @{ isEnabled = $false } }
    @{ Label = 'non-UTC'; Changes = @{ timeZone = 'Pacific/Auckland'; startTime = '2026-10-19T10:34:00+13:00' } }
    @{ Label = 'custom-interval'; Changes = @{ interval = 4; advancedSchedule = @{ weekDays = @('Tuesday', 'Friday') } } }
    @{ Label = 'custom-expiry'; Changes = @{ expiryTime = '2026-11-01T23:59:00Z' } }
  ) {
    $fixture = New-UpgradeFixture
    foreach ($key in $Changes.Keys) { $fixture.Schedule.properties[$key] = $Changes[$key] }
    $before = $fixture | ConvertTo-Json -Depth 30 -Compress
    $result = Assert-UpgradeFixture -Fixture $fixture -RequireExisting
    $result.Existing | Should -BeTrue
    [object]::ReferenceEquals($result.Schedule, $fixture.Schedule) | Should -BeTrue
    ($fixture | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
  }

  It 'distinguishes a fresh deployment from a required-existing upgrade' {
    $ownership = [pscustomobject]@{ JobScheduleId = $script:upgradeJobId; OwnedJobScheduleId = '' }
    $result = Assert-MaesterExistingAutomationResources -ExpectedAccountId 'fresh' -Account $null -Ownership $ownership
    $result.Existing | Should -BeFalse
    $result.JobSchedule | Should -BeNullOrEmpty
    $result.Schedule | Should -BeNullOrEmpty
    $result.Runbook | Should -BeNullOrEmpty
    { Assert-MaesterExistingAutomationResources -ExpectedAccountId 'fresh' -Account $null -Ownership $ownership -RequireExisting } |
      Should -Throw '*requires a verified existing*'
  }

  It 'rejects an absent or changed account' {
    $fixture = New-UpgradeFixture; $fixture.Account = $null
    { Assert-UpgradeFixture -Fixture $fixture } | Should -Throw '*account disappeared or changed*'
    $fixture = New-UpgradeFixture; $fixture.Account.id = "$script:upgradeAccountId-other"
    { Assert-UpgradeFixture -Fixture $fixture } | Should -Throw '*account disappeared or changed*'
  }

  It 'rejects <Kind> <Field> identity drift' -ForEach @(
    @{ Kind = 'Job'; Field = 'id' }, @{ Kind = 'Job'; Field = 'name' }, @{ Kind = 'Job'; Field = 'type' }
    @{ Kind = 'Schedule'; Field = 'id' }, @{ Kind = 'Schedule'; Field = 'name' }, @{ Kind = 'Schedule'; Field = 'type' }
    @{ Kind = 'Runbook'; Field = 'id' }, @{ Kind = 'Runbook'; Field = 'name' }, @{ Kind = 'Runbook'; Field = 'type' }
  ) {
    $fixture = New-UpgradeFixture
    $fixture[$Kind].$Field = 'another-resource'
    { Assert-UpgradeFixture -Fixture $fixture -RequireExisting } | Should -Throw '*disappeared, changed identity, or is ambiguous*'
  }

  It 'rejects missing or duplicate <Inventory> targets' -ForEach @(
    @{ Inventory = 'JobSchedules' }, @{ Inventory = 'Schedules' }, @{ Inventory = 'Runbooks' }
  ) {
    $fixture = New-UpgradeFixture; $fixture[$Inventory] = @()
    { Assert-UpgradeFixture -Fixture $fixture } | Should -Throw '*disappeared, changed identity, or is ambiguous*'
    $fixture = New-UpgradeFixture; $fixture[$Inventory] += $fixture[$Inventory][-1]
    { Assert-UpgradeFixture -Fixture $fixture } | Should -Throw '*disappeared, changed identity, or is ambiguous*'
  }

  It 'rejects unpublished runbook state <State>' -ForEach @(
    @{ State = 'New' }, @{ State = 'Edit' }, @{ State = '' }
  ) {
    $fixture = New-UpgradeFixture; $fixture.Runbook.properties.state = $State
    { Assert-UpgradeFixture -Fixture $fixture } | Should -Throw '*runbook is not published*'
  }

  It 'rejects a non-PowerShell existing runbook' {
    $fixture = New-UpgradeFixture; $fixture.Runbook.properties.runbookType = 'Python3'
    { Assert-UpgradeFixture -Fixture $fixture } | Should -Throw '*runbook type is not PowerShell*'
  }

  It 'rejects an association with a changed runbook, schedule or jobSchedule GUID' {
    foreach ($part in @('runbook', 'schedule', 'jobScheduleId')) {
      $fixture = New-UpgradeFixture
      if ($part -eq 'jobScheduleId') { $fixture.Job.properties.jobScheduleId = '44444444-4444-4444-4444-444444444444' }
      else { $fixture.Job.properties[$part].name = 'unrelated' }
      { Assert-UpgradeFixture -Fixture $fixture } | Should -Throw '*does not match the template ownership receipt*'
    }
  }

  It 'rejects a receipt-bound association that disappeared before resolve or write' {
    $fixture = New-UpgradeFixture
    { Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:upgradeAccountId -Account $fixture.Account -JobSchedules @() `
        -ReceiptAccountId $script:upgradeAccountId -ReceiptPrincipalId $script:upgradePrincipalId -ReceiptJobScheduleId $script:upgradeJobId } |
      Should -Throw '*jobSchedule disappeared*'
    { Assert-MaesterJobScheduleWriteTarget -ExpectedAccountId $script:upgradeAccountId -ExpectedPrincipalId $script:upgradePrincipalId `
        -JobScheduleId $script:upgradeJobId -Account $fixture.Account -JobSchedules @() -ReceiptAccountId $script:upgradeAccountId `
        -ReceiptPrincipalId $script:upgradePrincipalId -ReceiptJobScheduleId $script:upgradeJobId } | Should -Throw '*jobSchedule disappeared*'
  }

  It 'rejects partial adoption or adoption that conflicts with the receipt' {
    $fixture = New-UpgradeFixture
    { Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:upgradeAccountId -Account $fixture.Account `
        -JobSchedules $fixture.JobSchedules -AdoptAccountId $script:upgradeAccountId } | Should -Throw '*adoption request is incomplete*'
    { Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:upgradeAccountId -Account $fixture.Account `
        -JobSchedules $fixture.JobSchedules -ReceiptAccountId $script:upgradeAccountId -ReceiptPrincipalId $script:upgradePrincipalId `
        -ReceiptJobScheduleId $script:upgradeJobId -AdoptAccountId $script:upgradeAccountId -AdoptPrincipalId $script:upgradePrincipalId `
        -AdoptJobScheduleId '44444444-4444-4444-4444-444444444444' } | Should -Throw '*conflicts with the ownership receipt*'
    { Assert-MaesterJobScheduleWriteTarget -ExpectedAccountId $script:upgradeAccountId -ExpectedPrincipalId $script:upgradePrincipalId `
        -JobScheduleId $script:upgradeJobId -Account $fixture.Account -JobSchedules $fixture.JobSchedules `
        -AdoptAccountId $script:upgradeAccountId } | Should -Throw '*adoption target differs*'
  }
}

Describe 'Preprovision preservation decision uses readable complete live inventories' {
  It 'refreshes a stale existing flag from live state and leaves all Azure resources unchanged' {
    $scenario = New-UpgradePreProvisionScenario
    $scenario.Values.AUTOMATION_EXISTING_RESOURCES = 'false'
    $before = $scenario.Responses | ConvertTo-Json -Depth 30 -Compress
    Invoke-UpgradePreProvision -Scenario $scenario
    ($global:maesterUpgradeCalls -join '|') | Should -Match 'azd env set -e test AUTOMATION_EXISTING_RESOURCES true'
    ($global:maesterUpgradeCalls -join '|') | Should -Not -Match 'DELETE|--method PUT|lock delete'
    ($scenario.Responses | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
  }

  It 'verifies exact storage and account outputs before enabling bounded runtime-only preservation' {
    $scenario = New-UpgradePreProvisionScenario
    $scenario.Values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'true'
    $scenario.Values.STORAGE_ACCOUNT_NAME = 'stmaestertest'
    $scenario.Values.WEB_APP_ENABLED = 'false'; $scenario.Values.INCLUDE_WEB_APP = 'false'
    $scenario.Values.automationAccountName = 'aa-test'; $scenario.Values.automationPrincipalId = $script:upgradePrincipalId
    $storageId = '/subscriptions/sub-test/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/stmaestertest'
    $scenario.ExtraResources[$storageId] = [pscustomobject]@{ id = $storageId; name = 'stmaestertest'; type = 'Microsoft.Storage/storageAccounts'; tags = $scenario.Account.tags }
    $before = $scenario | ConvertTo-Json -Depth 30 -Compress
    Invoke-UpgradePreProvision -Scenario $scenario
    ($global:maesterUpgradeCalls -join '|') | Should -Match 'azd env set -e test AUTOMATION_UPGRADE_PRESERVE_ACCESS true'
    ($global:maesterUpgradeCalls -join '|') | Should -Match 'storageAccounts/stmaestertest\?'
    ($global:maesterUpgradeCalls -join '|') | Should -Not -Match 'DELETE|--method PUT|lock delete'
    ($scenario | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
  }

  It 'rejects runtime-only preservation when deployment outputs are absent' {
    $scenario = New-UpgradePreProvisionScenario; $scenario.Values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'true'
    { Invoke-UpgradePreProvision -Scenario $scenario } | Should -Throw '*STORAGE_ACCOUNT_NAME*'
    ($global:maesterUpgradeCalls -join '|') | Should -Not -Match 'env set|DELETE|--method PUT'
  }

  It 'rejects runtime-only preservation without a live existing account' {
    $scenario = New-UpgradePreProvisionScenario
    $scenario.GroupExists = 'false'; $scenario.Values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'true'
    foreach ($name in @('AUTOMATION_OWNED_ACCOUNT_ID', 'AUTOMATION_OWNED_PRINCIPAL_ID', 'AUTOMATION_OWNED_JOB_SCHEDULE_ID')) { $scenario.Values.Remove($name) }
    { Invoke-UpgradePreProvision -Scenario $scenario } | Should -Throw '*requires a verified existing*'
    ($global:maesterUpgradeCalls -join '|') | Should -Not -Match 'env set|DELETE|--method PUT'
  }

  It 'rejects an unreadable <Kind> inventory before any environment write' -ForEach @(
    @{ Kind = 'accounts' }, @{ Kind = 'account' }, @{ Kind = 'jobSchedules' }, @{ Kind = 'schedules' }, @{ Kind = 'runbooks' }
  ) {
    $scenario = New-UpgradePreProvisionScenario; $scenario.FailKind = $Kind
    { Invoke-UpgradePreProvision -Scenario $scenario } | Should -Throw '*Could not inspect*'
    ($global:maesterUpgradeCalls -join '|') | Should -Not -Match 'env set|DELETE|--method PUT'
  }

  It 'rejects malformed JSON for <Kind> before any environment write' -ForEach @(
    @{ Kind = 'schedules' }, @{ Kind = 'runbooks' }
  ) {
    $scenario = New-UpgradePreProvisionScenario; $scenario.RawKind = $Kind; $scenario.RawResponse = '{malformed'
    { Invoke-UpgradePreProvision -Scenario $scenario } | Should -Throw
    ($global:maesterUpgradeCalls -join '|') | Should -Not -Match 'env set|DELETE|--method PUT'
  }

  It 'rejects paginated <Kind> before any environment write' -ForEach @(
    @{ Kind = 'schedules' }, @{ Kind = 'runbooks' }
  ) {
    $scenario = New-UpgradePreProvisionScenario
    $scenario.Responses[$Kind] | Add-Member -NotePropertyName nextLink -NotePropertyValue 'https://management.azure.com/next'
    { Invoke-UpgradePreProvision -Scenario $scenario } | Should -Throw '*inventory was incomplete*'
    ($global:maesterUpgradeCalls -join '|') | Should -Not -Match 'env set|DELETE|--method PUT'
  }

  It 'does not treat a stale omission flag as evidence when the owned schedule disappeared' {
    $scenario = New-UpgradePreProvisionScenario; $scenario.Values.AUTOMATION_EXISTING_RESOURCES = 'true'
    $scenario.Responses.schedules.value = @()
    { Invoke-UpgradePreProvision -Scenario $scenario } | Should -Throw '*disappeared*'
    ($global:maesterUpgradeCalls -join '|') | Should -Not -Match 'env set|DELETE|--method PUT'
  }
}

Describe 'Preservation contract CI coverage' {
  It 'requires a pinned Bicep executable before running repository tests' {
    $workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../.github/workflows/validate.yml') -Raw
    $workflow | Should -Match 'az bicep install --version v0\.42\.1'
    $workflow | Should -Match 'BICEP_EXE=\$bicepPath'
    $workflow.IndexOf('az bicep install') | Should -BeLessThan $workflow.IndexOf('Invoke-Pester')
    $workflow | Should -Match 'if \(\$LASTEXITCODE -ne 0\)'
  }
}

Describe 'Compiled ARM preservation branches' {
  BeforeAll {
    # CI may run only the portable PowerShell contracts. Set BICEP_EXE to make
    # compiled contracts mandatory, or put the Bicep CLI on PATH to enable them.
    $script:upgradeBicep = $env:BICEP_EXE
    if (-not $script:upgradeBicep) { $script:upgradeBicep = (Get-Command bicep -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    if (-not $script:upgradeBicep -and $env:GITHUB_ACTIONS -eq 'true') {
      throw 'Bicep CLI is required for compiled ARM preservation contracts in CI.'
    }
    if ($script:upgradeBicep) {
      $output = Join-Path $TestDrive 'upgrade-main.json'
      & $script:upgradeBicep build (Join-Path $PSScriptRoot '../infra/main.bicep') --outfile $output
      if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed.' }
      $script:upgradeTemplate = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
    }

    function Split-UpgradeArmArguments {
      param([string]$Text)
      if ([string]::IsNullOrWhiteSpace($Text)) { return }
      $depth = 0; $quoted = $false; $start = 0
      for ($i = 0; $i -lt $Text.Length; $i++) {
        $character = $Text[$i]
        if ($character -eq "'") {
          if ($quoted -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { $i++; continue }
          $quoted = -not $quoted
        }
        elseif (-not $quoted) {
          if ($character -eq '(') { $depth++ }
          elseif ($character -eq ')') { $depth-- }
          elseif ($character -eq ',' -and $depth -eq 0) { $Text.Substring($start, $i - $start).Trim(); $start = $i + 1 }
        }
      }
      if ($quoted -or $depth -ne 0) { throw 'Unbalanced compiled ARM expression.' }
      $Text.Substring($start).Trim()
    }

    function Resolve-UpgradeArmExpression {
      param($Expression, [hashtable]$Parameters)
      # Deliberately restricted to the emitted conditions and runbook union.
      # Unknown functions fail closed; this does not emulate an ARM deployment.
      if ($Expression -isnot [string]) { return $Expression }
      $text = $Expression.Trim()
      if ($text.StartsWith('[') -and $text.EndsWith(']')) { $text = $text.Substring(1, $text.Length - 2) }
      if ($text -match "^'(?:[^']|'')*'$") { return $text.Substring(1, $text.Length - 2).Replace("''", "'") }
      if ($text -notmatch '^(?<name>[a-zA-Z]+)\((?<arguments>.*)\)$') { throw "Unsupported compiled ARM expression: $text" }
      $functionName = $Matches.name
      $arguments = @(Split-UpgradeArmArguments -Text $Matches.arguments)
      if ($functionName -eq 'if') {
        $branch = if (Resolve-UpgradeArmExpression -Expression $arguments[0] -Parameters $Parameters) { 1 } else { 2 }
        return Resolve-UpgradeArmExpression -Expression $arguments[$branch] -Parameters $Parameters
      }
      $values = @($arguments | ForEach-Object { Resolve-UpgradeArmExpression -Expression $_ -Parameters $Parameters })
      switch ($functionName) {
        'true' { return $true }
        'false' { return $false }
        'parameters' {
          if (-not $Parameters.ContainsKey([string]$values[0])) { throw "Missing test parameter: $($values[0])" }
          return $Parameters[[string]$values[0]]
        }
        'variables' {
          $value = $script:upgradeTemplate.variables.([string]$values[0])
          if ($value -is [string] -and $value.StartsWith('[')) { return Resolve-UpgradeArmExpression -Expression $value -Parameters $Parameters }
          return $value
        }
        'equals' { return [object]::Equals($values[0], $values[1]) }
        'toLower' { return ([string]$values[0]).ToLowerInvariant() }
        'not' { return -not [bool]$values[0] }
        'and' { return @($values | Where-Object { -not [bool]$_ }).Count -eq 0 }
        'or' { return @($values | Where-Object { [bool]$_ }).Count -gt 0 }
        'createObject' {
          $result = @{}
          for ($i = 0; $i -lt $values.Count; $i += 2) { $result[[string]$values[$i]] = $values[$i + 1] }
          return $result
        }
        'union' {
          $result = @{}
          foreach ($value in $values) { foreach ($key in $value.Keys) { $result[$key] = $value[$key] } }
          return $result
        }
        default { throw "Unsupported compiled ARM function: $functionName" }
      }
    }

    function Get-UpgradeArmParameters {
      param([string]$Existing = 'true', [string]$Preserve = 'true')
      @{
        existingAutomationResourcesOption = $Existing; preserveUpgradeAccessOption = $Preserve
        includeWebAppOption = 'true'; includeExchangeOption = 'true'; includeTeamsOption = 'true'; enableResourceLocks = $true
      }
    }

    function Get-ActiveUpgradeResources {
      param([hashtable]$Parameters)
      @($script:upgradeTemplate.resources | Where-Object {
        -not $_.PSObject.Properties['condition'] -or (Resolve-UpgradeArmExpression -Expression $_.condition -Parameters $Parameters)
      })
    }
  }

  BeforeEach {
    if (-not $script:upgradeBicep) { Set-ItResult -Skipped -Because 'Bicep CLI not available. Set BICEP_EXE to require compiled ARM checks.' }
  }

  It 'constrains both omission flags to true or false with safe fresh defaults' {
    foreach ($name in @('existingAutomationResourcesOption', 'preserveUpgradeAccessOption')) {
      $parameter = $script:upgradeTemplate.parameters.$name
      $parameter.type | Should -Be 'string'
      $parameter.defaultValue | Should -Be 'false'
      $parameter.allowedValues | Should -Be @('true', 'false')
    }
  }

  It 'selects the intended resource branches with existing=<Existing>, preserve=<Preserve>' -ForEach @(
    @{ Existing = 'false'; Preserve = 'false'; ScheduleCount = 1 }
    @{ Existing = 'true'; Preserve = 'false'; ScheduleCount = 0 }
    @{ Existing = 'true'; Preserve = 'true'; ScheduleCount = 0 }
    @{ Existing = 'false'; Preserve = 'true'; ScheduleCount = 0 }
  ) {
    $active = @(Get-ActiveUpgradeResources -Parameters (Get-UpgradeArmParameters -Existing $Existing -Preserve $Preserve))
    @($active | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/schedules').Count | Should -Be $ScheduleCount
    @($active | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/jobSchedules').Count | Should -Be 0
    @($active | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/runtimeEnvironments').Count | Should -Be 1
    @($active | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/runtimeEnvironments/packages').Count | Should -Be 9
    @($active | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/runbooks').Count | Should -Be 1
    if ($Preserve -eq 'true') {
      $active.Count | Should -Be 11
      @($active | Where-Object type -NotIn @(
        'Microsoft.Automation/automationAccounts/runtimeEnvironments', 'Microsoft.Automation/automationAccounts/runtimeEnvironments/packages',
        'Microsoft.Automation/automationAccounts/runbooks'
      )).Count | Should -Be 0
    }
    else {
      foreach ($type in @('Microsoft.Automation/automationAccounts', 'Microsoft.Storage/storageAccounts', 'Microsoft.Storage/storageAccounts/blobServices',
          'Microsoft.Storage/storageAccounts/blobServices/containers', 'Microsoft.Storage/storageAccounts/managementPolicies',
          'Microsoft.Authorization/roleAssignments', 'Microsoft.Authorization/locks', 'Microsoft.Automation/automationAccounts/variables', 'Microsoft.Resources/deployments')) {
        @($active | Where-Object type -EQ $type).Count | Should -BeGreaterThan 0
      }
    }
  }

  It 'omits seed content and user runbook settings with existing=<Existing>, preserve=<Preserve>' -ForEach @(
    @{ Existing = 'true'; Preserve = 'false' }, @{ Existing = 'true'; Preserve = 'true' }, @{ Existing = 'false'; Preserve = 'true' }
  ) {
    $runbook = @($script:upgradeTemplate.resources | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/runbooks')[0]
    $properties = Resolve-UpgradeArmExpression -Expression $runbook.properties -Parameters (Get-UpgradeArmParameters -Existing $Existing -Preserve $Preserve)
    @($properties.Keys).Count | Should -Be 2
    $properties.runbookType | Should -Be 'PowerShell'
    $properties.runtimeEnvironment | Should -Match '^PowerShell-(74|76)-Maester$'
    $properties.runtimeEnvironment | Should -Be $script:upgradeTemplate.variables.runtimeEnvironmentName
    foreach ($key in @('publishContentLink', 'description', 'logProgress', 'logVerbose')) { $properties.ContainsKey($key) | Should -BeFalse }
  }

  It 'keeps optional packages disabled in bounded mode when their options are false' {
    $parameters = Get-UpgradeArmParameters
    $parameters.includeExchangeOption = 'false'; $parameters.includeTeamsOption = 'false'
    $active = @(Get-ActiveUpgradeResources -Parameters $parameters)
    $active.Count | Should -Be 9
    @($active | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/runtimeEnvironments/packages').Count | Should -Be 7
    @($active | Where-Object { $_.name -match "'ExchangeOnlineManagement'|'MicrosoftTeams'" }).Count | Should -Be 0
  }

  It 'retains the pinned seed content and logging defaults only for fresh resources' {
    $runbook = @($script:upgradeTemplate.resources | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/runbooks')[0]
    $properties = Resolve-UpgradeArmExpression -Expression $runbook.properties -Parameters (Get-UpgradeArmParameters -Existing 'false' -Preserve 'false')
    $properties.publishContentLink.uri | Should -Match '^https://raw\.githubusercontent\.com/maester365/maester/[a-f0-9]{40}/powershell/public/Invoke-Maester\.ps1$'
    $properties.publishContentLink.contentHash.algorithm | Should -Be 'sha256'
    $properties.publishContentLink.contentHash.value | Should -Match '^[A-F0-9]{64}$'
    $properties.logProgress | Should -BeTrue
    $properties.logVerbose | Should -BeFalse
  }

  It 'keeps fresh schedule defaults and dependencies without emitting an association' {
    $schedule = @($script:upgradeTemplate.resources | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/schedules')[0]
    $schedule.properties.frequency | Should -Be 'Week'
    $schedule.properties.interval | Should -Be 1
    $schedule.properties.timeZone | Should -Be 'UTC'
    $schedule.properties.advancedSchedule.weekDays | Should -Be @('Sunday')
    $schedule.properties.startTime | Should -Be "[dateTimeAdd(parameters('deploymentTimestamp'), 'P7D')]"
    ($schedule.dependsOn -join '|') | Should -Match "resourceId\('Microsoft.Automation/automationAccounts',"
    $runtime = @($script:upgradeTemplate.resources | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/runtimeEnvironments')[0]
    ($runtime.dependsOn -join '|') | Should -Match "resourceId\('Microsoft.Automation/automationAccounts',"
    foreach ($package in @($script:upgradeTemplate.resources | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/runtimeEnvironments/packages')) {
      ($package.dependsOn -join '|') | Should -Match "resourceId\('Microsoft.Automation/automationAccounts/runtimeEnvironments',"
    }
    $runbook = @($script:upgradeTemplate.resources | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/runbooks')[0]
    @($runbook.dependsOn | Where-Object { $_ -match "resourceId\('Microsoft.Automation/automationAccounts/runtimeEnvironments/packages'," }).Count | Should -Be 9
    @($script:upgradeTemplate.resources | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/jobSchedules').Count | Should -Be 0
  }
}
