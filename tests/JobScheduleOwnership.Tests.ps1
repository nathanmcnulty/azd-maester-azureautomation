BeforeAll {
  . (Join-Path $PSScriptRoot '../scripts/JobScheduleOwnership.ps1')
  $script:hookPath = Join-Path $PSScriptRoot '../scripts/Run-AzdPreProvision.ps1'
  $script:accountId = '/subscriptions/sub-test/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-test'
  $script:principalId = '11111111-1111-1111-1111-111111111111'
  $script:scheduleId = '22222222-2222-2222-2222-222222222222'
  $script:unrelatedId = '33333333-3333-3333-3333-333333333333'
  $script:account = [pscustomobject]@{ id = $script:accountId; identity = @{ principalId = $script:principalId } }
  $script:owned = [pscustomobject]@{ id = "$($script:accountId)/jobSchedules/$($script:scheduleId)"; type = 'Microsoft.Automation/automationAccounts/jobSchedules'; name = $script:scheduleId; properties = @{ jobScheduleId = $script:scheduleId; schedule = @{ name = 'maester-weekly-sunday' }; runbook = @{ name = 'maester-runbook' } } }
  $script:unrelated = [pscustomobject]@{ id = "$($script:accountId)/jobSchedules/$($script:unrelatedId)"; type = 'Microsoft.Automation/automationAccounts/jobSchedules'; name = $script:unrelatedId; properties = @{ jobScheduleId = $script:unrelatedId; schedule = @{ name = 'other' }; runbook = @{ name = 'other' } } }

  function Invoke-OfflinePreProvision {
    param([hashtable]$Scenario)
    $names = @('AZURE_ENV_NAME', 'AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_LOCATION', 'AUTOMATION_UPGRADE_PRESERVE_ACCESS', 'AUTOMATION_EXISTING_RESOURCES', 'AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION', 'AUTOMATION_ADOPT_SOLUTION_TAG')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
      $env:AZURE_ENV_NAME = 'test'
      $env:AZURE_SUBSCRIPTION_ID = 'sub-test'
      $env:AZURE_TENANT_ID = 'tenant-test'
      $env:AZURE_LOCATION = 'westus'
      Remove-Item Env:AUTOMATION_UPGRADE_PRESERVE_ACCESS -ErrorAction SilentlyContinue
      Remove-Item Env:AUTOMATION_EXISTING_RESOURCES -ErrorAction SilentlyContinue
      Remove-Item Env:AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION -ErrorAction SilentlyContinue
      if ($Scenario.ContainsKey('ProcessValues')) { foreach ($key in $Scenario.ProcessValues.Keys) { [Environment]::SetEnvironmentVariable($key, $Scenario.ProcessValues[$key]) } }
      $global:maesterOfflineScenario = $Scenario
      $global:maesterOfflineScenario.LocalContent = Get-Content (Join-Path (Split-Path $script:hookPath) 'Invoke-MaesterAutomationRunbook.ps1') -Raw
      $global:maesterOfflineCalls = [Collections.Generic.List[string]]::new()
      $global:maesterOfflineWrites = @{}
      function Import-Module { param([string]$Name, [switch]$Force) }
      function Invoke-MaesterPreProvision { param($SolutionName, $SubscriptionId, $TenantId, $Location) }
      function azd {
        $global:maesterOfflineCalls.Add("azd $($args -join ' ')")
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'env' -and $args[1] -eq 'get-values') {
          return ($global:maesterOfflineScenario.Values | ConvertTo-Json -Compress)
        }
        if ($args[0] -eq 'env' -and $args[1] -eq 'set') {
          if ($global:maesterOfflineScenario.ContainsKey('FailMetadataSet') -and $global:maesterOfflineScenario.FailMetadataSet -and $args[4] -eq 'AUTOMATION_EXISTING_RUNBOOK_METADATA') { $global:LASTEXITCODE = 1; return }
          $global:maesterOfflineWrites[[string]$args[4]] = [string]$args[5]
          return
        }
        throw "Unexpected azd call: $($args -join ' ')"
      }
      function az {
        $command = $args -join ' '
        $global:maesterOfflineCalls.Add("az $command")
        $global:LASTEXITCODE = 0
        if ($command -like 'group exists *') { return $global:maesterOfflineScenario.GroupExists }
        if ($command -like 'automation account list *') { return '[]' }
        if ($command -like 'rest --method GET *') {
          if ($command -like '*/runbooks/maester-runbook/content?*') {
            if ($global:maesterOfflineScenario.ContainsKey('FailContent') -and $global:maesterOfflineScenario.FailContent) { $global:LASTEXITCODE = 1; return }
            $outputPath = $args[([array]::IndexOf($args, '--output-file') + 1)]
            $content = if ($global:maesterOfflineScenario.ContainsKey('PublishedContent')) { $global:maesterOfflineScenario.PublishedContent } else { $global:maesterOfflineScenario.LocalContent }
            [IO.File]::WriteAllText($outputPath, $content)
            return
          }
          if ($command -like '*/runbooks/maester-runbook?*') {
            if ($global:maesterOfflineScenario.ContainsKey('FailMetadataRead') -and $global:maesterOfflineScenario.FailMetadataRead) { $global:LASTEXITCODE = 1; return '' }
            if ($global:maesterOfflineScenario.ContainsKey('RawMetadataRead')) { return $global:maesterOfflineScenario.RawMetadataRead }
            return ($global:maesterOfflineScenario.RunbookMetadata | ConvertTo-Json -Depth 12 -Compress)
          }
          if ($global:maesterOfflineScenario.ContainsKey('UnreadableKind') -and $command -like "*/$($global:maesterOfflineScenario.UnreadableKind)?*") { $global:LASTEXITCODE = 1; return '' }
          if ($command -like '*resourceGroups/rg-test?api-version=2021-04-01*') { return (@{ id = '/subscriptions/sub-test/resourceGroups/rg-test'; name = 'rg-test'; type = 'Microsoft.Resources/resourceGroups' } | ConvertTo-Json -Compress) }
          if ($command -like '*Microsoft.Storage/storageAccounts/stmaestero7scshewul3pm?*') { return ($global:maesterOfflineScenario.Storage | ConvertTo-Json -Depth 12 -Compress) }
          if ($command -like '*/schedules?*') { return ($global:maesterOfflineScenario.Schedules | ConvertTo-Json -Depth 12 -Compress) }
          if ($command -like '*/runbooks?*') { return ($global:maesterOfflineScenario.Runbooks | ConvertTo-Json -Depth 12 -Compress) }
          if ($command -like '*/jobSchedules?*') { return ($global:maesterOfflineScenario.ScheduleList | ConvertTo-Json -Depth 12 -Compress) }
          if ($command -like '*automationAccounts/aa-test?*') { return ($global:maesterOfflineScenario.Account | ConvertTo-Json -Depth 12 -Compress) }
          return ($global:maesterOfflineScenario.AccountList | ConvertTo-Json -Depth 12 -Compress)
        }
        throw "Unexpected Azure call: $command"
      }
      & $script:hookPath
    }
    finally {
      foreach ($name in $names) { if ($null -eq $saved[$name]) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
      $global:LASTEXITCODE = 0
    }
  }

  function New-OfflineScenario {
    param([string]$GroupExists = 'true')
    $values = @{ AZURE_ENV_NAME = 'test'; AZURE_SUBSCRIPTION_ID = 'sub-test'; AZURE_TENANT_ID = 'tenant-test'; AZURE_RESOURCE_GROUP = 'rg-test'; AZURE_LOCATION = 'westus' }
    $account = [pscustomobject]@{ id = $script:accountId; name = 'aa-test'; type = 'Microsoft.Automation/automationAccounts'; identity = @{ principalId = $script:principalId; type = 'SystemAssigned' }; tags = @{ workload = 'maester'; solution = 'automation-account'; environment = 'test'; managedBy = 'azd' } }
    $scenario = @{ Values = $values; GroupExists = $GroupExists; AccountList = @{ value = @($account) }; Account = $account; ScheduleList = @{ value = @($script:owned, $script:unrelated) }; Schedules = @{ value = @(@{ id = "$($script:accountId)/schedules/maester-weekly-sunday"; name = 'maester-weekly-sunday'; type = 'Microsoft.Automation/automationAccounts/schedules'; properties = @{ isEnabled = $true; startTime = '2026-10-18T10:34:00Z'; timeZone = 'UTC'; interval = 1 } }) }; Runbooks = @{ value = @(@{ id = "$($script:accountId)/runbooks/maester-runbook"; name = 'maester-runbook'; type = 'Microsoft.Automation/automationAccounts/runbooks'; properties = @{ state = 'Published'; runbookType = 'PowerShell' } }) } }
    $scenario.RunbookMetadata = @{
      id = "$($script:accountId)/runbooks/maester-runbook"; name = 'maester-runbook'
      type = 'Microsoft.Automation/automationAccounts/runbooks'; location = 'westus'
      tags = @{}; properties = @{ state = 'Published'; runbookType = 'PowerShell'; description = 'Existing description'; logProgress = $true; logVerbose = $false; logActivityTrace = 0 }
    }
    return $scenario
  }
}

Describe 'Automation jobSchedule ownership rules' {
  It 'reuses only the exact receipt-bound template association in a mixed account' {
    $result = Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account `
      -JobSchedules @($script:unrelated, $script:owned) -ReceiptAccountId $script:accountId `
      -ReceiptPrincipalId $script:principalId -ReceiptJobScheduleId $script:scheduleId
    $result.JobScheduleId | Should -Be $script:scheduleId
    $result.OwnedJobScheduleId | Should -Be $script:scheduleId
  }

  It 'rejects an existing account without exact receipt or adoption' {
    { Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account `
        -JobSchedules @($script:owned) } | Should -Throw '*Explicit adoption*'
  }

  It 'rejects prior receipt or adoption data when the expected account is absent' {
    { Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $null `
        -ReceiptAccountId $script:accountId -ReceiptPrincipalId $script:principalId `
        -ReceiptJobScheduleId $script:scheduleId } | Should -Throw '*no matching live account*'
    { Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $null `
        -ReceiptAccountId $script:accountId } | Should -Throw '*no matching live account*'
    { Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $null `
        -AdoptAccountId $script:accountId -AdoptPrincipalId $script:principalId `
        -AdoptJobScheduleId $script:scheduleId } | Should -Throw '*no matching live account*'
  }

  It 'rejects a wrong principal, partial receipt, ID collision, and duplicate template links' {
    { Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account `
        -JobSchedules @($script:owned) -ReceiptAccountId $script:accountId -ReceiptPrincipalId $script:unrelatedId `
        -ReceiptJobScheduleId $script:scheduleId } | Should -Throw '*receipt does not match*'
    { Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account `
        -JobSchedules @($script:owned) -ReceiptAccountId $script:accountId } | Should -Throw '*incomplete*'
    { Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account `
        -JobSchedules @($script:unrelated) -ReceiptAccountId $script:accountId -ReceiptPrincipalId $script:principalId `
        -ReceiptJobScheduleId $script:unrelatedId } | Should -Throw '*different schedule*'
    $duplicate = [pscustomobject]@{ name = '44444444-4444-4444-4444-444444444444'; properties = @{ jobScheduleId = '44444444-4444-4444-4444-444444444444'; schedule = @{ name = 'maester-weekly-sunday' }; runbook = @{ name = 'maester-runbook' } } }
    { Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account `
        -JobSchedules @($script:owned, $duplicate) -ReceiptAccountId $script:accountId `
        -ReceiptPrincipalId $script:principalId -ReceiptJobScheduleId $script:scheduleId } | Should -Throw '*More than one*'
  }

  It 'rejects an unrelated association before PUT and verifies the completed receipt' {
    { Assert-MaesterJobScheduleWriteTarget -ExpectedAccountId $script:accountId -ExpectedPrincipalId $script:principalId `
        -JobScheduleId $script:unrelatedId -Account $script:account -JobSchedules @($script:unrelated) } | Should -Throw '*another association*'
    { Assert-MaesterOwnershipReceiptTarget -ExpectedAccountId $script:accountId -ExpectedPrincipalId $script:principalId `
        -ExpectedJobScheduleId $script:scheduleId -Account $script:account -JobSchedule $script:owned } | Should -Not -Throw
    $wrongRunbook = [pscustomobject]@{ name = $script:unrelatedId; properties = @{ jobScheduleId = $script:unrelatedId; schedule = @{ name = 'maester-weekly-sunday' }; runbook = @{ name = 'other' } } }
    { Assert-MaesterJobScheduleWriteTarget -ExpectedAccountId $script:accountId -ExpectedPrincipalId $script:principalId `
        -JobScheduleId $script:scheduleId -Account $script:account -JobSchedules @($wrongRunbook) } | Should -Throw '*unexpected runbook*'
  }
}

Describe 'Preprovision hook preserves Azure state' {
  It 'generates an ID for a verified absent resource group without listing or deleting resources' {
    $scenario = New-OfflineScenario -GroupExists 'false'
    Invoke-OfflinePreProvision -Scenario $scenario
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'rest|DELETE|lock delete'
    ($global:maesterOfflineCalls -join '|') | Should -Match 'azd env set -e test AUTOMATION_JOB_SCHEDULE_ID'
  }

  It 'allows a first provision before azd has recorded a resource group' {
    $scenario = New-OfflineScenario
    $scenario.Values.Remove('AZURE_RESOURCE_GROUP')
    Invoke-OfflinePreProvision -Scenario $scenario
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'group exists|rest|DELETE'
    ($global:maesterOfflineCalls -join '|') | Should -Match 'azd env set -e test AUTOMATION_JOB_SCHEDULE_ID'
  }

  It 'does not discard a prior receipt when its resource group is absent' {
    $scenario = New-OfflineScenario -GroupExists 'false'
    $scenario.Values.AUTOMATION_OWNED_ACCOUNT_ID = $script:accountId
    $scenario.Values.AUTOMATION_OWNED_PRINCIPAL_ID = $script:principalId
    $scenario.Values.AUTOMATION_OWNED_JOB_SCHEDULE_ID = $script:scheduleId
    { Invoke-OfflinePreProvision -Scenario $scenario } | Should -Throw '*target resource group is absent*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|DELETE'
  }

  It 'accepts a normal empty account inventory and creates a fresh ID' {
    $scenario = New-OfflineScenario
    $scenario.AccountList = @{ value = @() }
    Invoke-OfflinePreProvision -Scenario $scenario
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'DELETE|lock delete'
    ($global:maesterOfflineCalls -join '|') | Should -Match 'azd env set -e test AUTOMATION_JOB_SCHEDULE_ID'
  }

  It 'fails closed when an empty account inventory conflicts with a complete or partial prior binding' {
    foreach ($prior in @(
        @{ AUTOMATION_OWNED_ACCOUNT_ID = $script:accountId; AUTOMATION_OWNED_PRINCIPAL_ID = $script:principalId; AUTOMATION_OWNED_JOB_SCHEDULE_ID = $script:scheduleId },
        @{ AUTOMATION_OWNED_ACCOUNT_ID = $script:accountId },
        @{ AUTOMATION_ADOPT_ACCOUNT_ID = $script:accountId; AUTOMATION_ADOPT_PRINCIPAL_ID = $script:principalId; AUTOMATION_ADOPT_JOB_SCHEDULE_ID = $script:scheduleId }
      )) {
      $scenario = New-OfflineScenario
      $scenario.AccountList = @{ value = @() }
      foreach ($key in $prior.Keys) { $scenario.Values[$key] = $prior[$key] }
      { Invoke-OfflinePreProvision -Scenario $scenario } | Should -Throw '*no matching live account*'
      ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|DELETE|lock delete'
    }
  }

  It 'preserves the exact association before a failed ARM redeployment' {
    $scenario = New-OfflineScenario
    $scenario.Values.AUTOMATION_OWNED_ACCOUNT_ID = $script:accountId
    $scenario.Values.AUTOMATION_OWNED_PRINCIPAL_ID = $script:principalId
    $scenario.Values.AUTOMATION_OWNED_JOB_SCHEDULE_ID = $script:scheduleId
    Invoke-OfflinePreProvision -Scenario $scenario
    ($global:maesterOfflineCalls -join '|') | Should -Match "AUTOMATION_JOB_SCHEDULE_ID $($script:scheduleId)"
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'DELETE|lock delete'
  }

  It 'fails closed on a mismatched receipt before writing the jobSchedule ID' {
    $scenario = New-OfflineScenario
    $scenario.Values.AUTOMATION_OWNED_ACCOUNT_ID = $script:accountId
    $scenario.Values.AUTOMATION_OWNED_PRINCIPAL_ID = $script:unrelatedId
    $scenario.Values.AUTOMATION_OWNED_JOB_SCHEDULE_ID = $script:scheduleId
    { Invoke-OfflinePreProvision -Scenario $scenario } | Should -Throw '*receipt does not match*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|DELETE|lock delete'
  }

  It 'rejects paginated or malformed account inventories without writing' {
    $scenario = New-OfflineScenario
    $scenario.AccountList = @{ value = @(); nextLink = 'https://management.azure.com/next' }
    { Invoke-OfflinePreProvision -Scenario $scenario } | Should -Throw '*incomplete*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|DELETE'
    $scenario.AccountList = @{ value = $null }
    { Invoke-OfflinePreProvision -Scenario $scenario } | Should -Throw '*incomplete*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|DELETE'
  }

  It 'rejects a paginated jobSchedule inventory before writing' {
    $scenario = New-OfflineScenario
    $scenario.ScheduleList.nextLink = 'https://management.azure.com/next'
    { Invoke-OfflinePreProvision -Scenario $scenario } | Should -Throw '*jobSchedule inventory was incomplete*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|DELETE'
  }

  It 'does not treat an unreadable group as a fresh deployment' {
    $scenario = New-OfflineScenario -GroupExists 'unknown'
    { Invoke-OfflinePreProvision -Scenario $scenario } | Should -Throw '*Could not verify*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|DELETE'
  }
}


Describe 'Upgrade preservation preprovision discovery' {
  BeforeEach {
    $script:scenario = New-OfflineScenario
    $script:scenario.Values.AUTOMATION_OWNED_ACCOUNT_ID = $script:accountId
    $script:scenario.Values.AUTOMATION_OWNED_PRINCIPAL_ID = $script:principalId
    $script:scenario.Values.AUTOMATION_OWNED_JOB_SCHEDULE_ID = $script:scheduleId
  }

  It 'recomputes existing omission flags from live ownership rather than trusting saved flags' {
    $script:scenario.Values.AUTOMATION_EXISTING_RESOURCES = 'false'
    Invoke-OfflinePreProvision -Scenario $script:scenario
    ($global:maesterOfflineCalls -join '|') | Should -Match 'AUTOMATION_EXISTING_RESOURCES true'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'az rest --method (PUT|POST|DELETE)|lock delete'
  }

  It 'rejects a disappeared receipt association before any environment writes' {
    $script:scenario.ScheduleList.value = @($script:unrelated)
    { Invoke-OfflinePreProvision -Scenario $script:scenario } | Should -Throw '*disappeared*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|DELETE'
  }

  It 'rejects a disappeared schedule or runbook before any environment writes' {
    foreach ($kind in @('Schedules', 'Runbooks')) {
      $scenario = New-OfflineScenario
      foreach ($key in @('AUTOMATION_OWNED_ACCOUNT_ID', 'AUTOMATION_OWNED_PRINCIPAL_ID', 'AUTOMATION_OWNED_JOB_SCHEDULE_ID')) { $scenario.Values[$key] = $script:scenario.Values[$key] }
      $scenario[$kind].value = @()
      { Invoke-OfflinePreProvision -Scenario $scenario } | Should -Throw '*disappeared*'
      ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|DELETE'
    }
  }

  It 'fails closed on unreadable, malformed or paginated schedule and runbook inventory' {
    foreach ($kind in @('schedules', 'runbooks')) {
      $script:scenario.UnreadableKind = $kind
      { Invoke-OfflinePreProvision -Scenario $script:scenario } | Should -Throw '*Could not inspect*'
      ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|DELETE'
      $script:scenario.Remove('UnreadableKind')
      $script:scenario[$kind].nextLink = 'https://management.azure.com/next'
      { Invoke-OfflinePreProvision -Scenario $script:scenario } | Should -Throw '*incomplete*'
      ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|DELETE'
      $script:scenario[$kind].Remove('nextLink')
    }
  }

  It 'rejects runtime-only preservation on a verified absent deployment' {
    $scenario = New-OfflineScenario -GroupExists 'false'
    $scenario.Values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'true'
    { Invoke-OfflinePreProvision -Scenario $scenario } | Should -Throw '*requires a verified existing*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|DELETE'
  }

  It 'requires exact existing output targets for the runtime-only deployment mode' {
    $script:scenario.Values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'true'
    $script:scenario.Values.STORAGE_ACCOUNT_NAME = 'stmaestero7scshewul3pm'
    $script:scenario.Values.WEB_APP_ENABLED = 'false'
    $script:scenario.Values.INCLUDE_WEB_APP = 'false'
    $script:scenario.Values.automationAccountName = 'aa-test'
    $script:scenario.Values.automationPrincipalId = $script:principalId
    $script:scenario.Storage = @{ id = '/subscriptions/sub-test/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/stmaestero7scshewul3pm'; name = 'stmaestero7scshewul3pm'; type = 'Microsoft.Storage/storageAccounts'; tags = @{ workload = 'maester'; solution = 'automation-account'; environment = 'test'; managedBy = 'azd' } }
    Invoke-OfflinePreProvision -Scenario $script:scenario
    ($global:maesterOfflineCalls -join '|') | Should -Match 'AUTOMATION_UPGRADE_PRESERVE_ACCESS true'
    $script:scenario.Storage.id = '/subscriptions/other/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/stmaestero7scshewul3pm'
    { Invoke-OfflinePreProvision -Scenario $script:scenario } | Should -Throw '*exact subscription*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|DELETE'
  }
}


Describe 'Upgrade flag provenance' {
  It 'rejects either process/environment control mismatch before writing derived flags' {
    foreach ($name in @('AUTOMATION_UPGRADE_PRESERVE_ACCESS', 'AUTOMATION_EXISTING_RESOURCES', 'AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION', 'AUTOMATION_ADOPT_SOLUTION_TAG')) {
      foreach ($selected in @('true', 'false')) {
        $scenario = New-OfflineScenario -GroupExists 'false'
        $scenario.Values[$name] = $selected
        $scenario.ProcessValues = @{ $name = $(if ($selected -eq 'true') { 'false' } else { 'true' }) }
        { Invoke-OfflinePreProvision -Scenario $scenario } | Should -Throw '*differs from the selected*'
        ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|DELETE'
      }
    }
  }
}


Describe 'Runtime-only script authorization boundary' {
  BeforeEach {
    $script:contentScenario = New-OfflineScenario
    $script:contentScenario.Values.AUTOMATION_OWNED_ACCOUNT_ID = $script:accountId
    $script:contentScenario.Values.AUTOMATION_OWNED_PRINCIPAL_ID = $script:principalId
    $script:contentScenario.Values.AUTOMATION_OWNED_JOB_SCHEDULE_ID = $script:scheduleId
    $script:contentScenario.Values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'true'
    $script:contentScenario.Values.STORAGE_ACCOUNT_NAME = 'stmaestero7scshewul3pm'
    $script:contentScenario.Values.WEB_APP_ENABLED = 'false'
    $script:contentScenario.Values.INCLUDE_WEB_APP = 'false'
    $script:contentScenario.Values.automationAccountName = 'aa-test'
    $script:contentScenario.Values.automationPrincipalId = $script:principalId
    $script:contentScenario.Storage = @{ id = '/subscriptions/sub-test/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/stmaestero7scshewul3pm'; name = 'stmaestero7scshewul3pm'; type = 'Microsoft.Storage/storageAccounts'; tags = @{ workload = 'maester'; solution = 'automation-account'; environment = 'test'; managedBy = 'azd' } }
  }

  It 'rejects different published workflow bytes before ARM flags or other writes' {
    $script:contentScenario.PublishedContent = '# unreviewed live script'
    { Invoke-OfflinePreProvision -Scenario $script:contentScenario } | Should -Throw '*requires matching published/local*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|--method (PUT|POST|DELETE)'
  }

  It 'fails closed when the published workflow bytes cannot be read' {
    $script:contentScenario.FailContent = $true
    { Invoke-OfflinePreProvision -Scenario $script:contentScenario } | Should -Throw '*Could not verify the existing published runbook content*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|--method (PUT|POST|DELETE)'
  }

  It 'rejects an empty published workflow response before ARM flags or other writes' {
    $script:contentScenario.PublishedContent = ''
    { Invoke-OfflinePreProvision -Scenario $script:contentScenario } | Should -Throw '*Could not verify the existing published runbook content*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|--method (PUT|POST|DELETE)'
  }

  It 'accepts identical content with only BOM or CRLF differences before enabling runtime-only mode' {
    $localContent = Get-Content (Join-Path (Split-Path $script:hookPath) 'Invoke-MaesterAutomationRunbook.ps1') -Raw
    $script:contentScenario.PublishedContent = [string][char]0xFEFF + $localContent.Replace("`n", "`r`n")
    Invoke-OfflinePreProvision -Scenario $script:contentScenario
    ($global:maesterOfflineCalls -join '|') | Should -Match 'AUTOMATION_UPGRADE_PRESERVE_ACCESS true'
  }
}


Describe 'Explicit custom metadata preprovision binding' {
  BeforeEach {
    $script:customScenario = New-OfflineScenario
    $v = $script:customScenario.Values
    $v.AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'true'
    $v.AUTOMATION_ADOPT_SOLUTION_TAG = 'Reviewed custom deployment'
    $v.AUTOMATION_OWNED_ACCOUNT_ID = $script:accountId
    $v.AUTOMATION_OWNED_PRINCIPAL_ID = $script:principalId
    $v.AUTOMATION_OWNED_JOB_SCHEDULE_ID = $script:scheduleId
    $v.STORAGE_ACCOUNT_NAME = 'stmaestero7scshewul3pm'
    $v.WEB_APP_ENABLED = 'false'; $v.INCLUDE_WEB_APP = 'false'
    $v.automationAccountName = 'aa-test'; $v.automationPrincipalId = $script:principalId
    $script:customScenario.Account.tags.solution = 'Reviewed custom deployment'
    $script:customScenario.Storage = @{ id = '/subscriptions/sub-test/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/stmaestero7scshewul3pm'; name = 'stmaestero7scshewul3pm'; type = 'Microsoft.Storage/storageAccounts'; tags = @{ workload = 'maester'; solution = 'Reviewed custom deployment'; environment = 'test'; managedBy = 'azd' } }
  }

  It 'accepts explicitly bound custom metadata before ARM without retagging or fabricating a receipt' {
    $beforeAccount = $script:customScenario.Account | ConvertTo-Json -Depth 20 -Compress
    $beforeValues = $script:customScenario.Values | ConvertTo-Json -Depth 20 -Compress
    Invoke-OfflinePreProvision -Scenario $script:customScenario
    ($script:customScenario.Account | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly $beforeAccount
    ($script:customScenario.Values | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly $beforeValues
    ($global:maesterOfflineCalls -join '|') | Should -Match 'AUTOMATION_EXISTING_RESOURCES true'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'AUTOMATION_OWNED_|--method (PUT|PATCH|POST|DELETE)'
  }

  It 'rejects an unbound or wrong-case custom tag before any provision writes' {
    $script:customScenario.Values.Remove('AUTOMATION_OWNED_PRINCIPAL_ID')
    { Invoke-OfflinePreProvision -Scenario $script:customScenario } | Should -Throw '*incomplete*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|--method (PUT|PATCH|POST|DELETE)'
    $script:customScenario.Values.AUTOMATION_OWNED_PRINCIPAL_ID = $script:principalId
    $script:customScenario.Account.tags.solution = 'reviewed custom deployment'
    { Invoke-OfflinePreProvision -Scenario $script:customScenario } | Should -Throw '*does not match the template deployment target*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|--method (PUT|PATCH|POST|DELETE)'
  }
}


Describe 'Fresh existing runbook metadata capture' {
  BeforeEach {
    $script:metadataScenario = New-OfflineScenario
    $script:metadataScenario.Values.AUTOMATION_OWNED_ACCOUNT_ID = $script:accountId
    $script:metadataScenario.Values.AUTOMATION_OWNED_PRINCIPAL_ID = $script:principalId
    $script:metadataScenario.Values.AUTOMATION_OWNED_JOB_SCHEDULE_ID = $script:scheduleId
    $script:metadataScenario.Values.AUTOMATION_EXISTING_RUNBOOK_METADATA = '{"stale":"must not be reused"}'
  }

  It 'captures the fresh exact GET instead of stale environment or list metadata' {
    $script:metadataScenario.RunbookMetadata.properties.description = "Fresh 'quoted' Δ`nmetadata"
    $script:metadataScenario.RunbookMetadata.properties.logProgress = $false
    $script:metadataScenario.RunbookMetadata.properties.logVerbose = $true
    $script:metadataScenario.RunbookMetadata.properties.logActivityTrace = 3
    $script:metadataScenario.RunbookMetadata.tags = @{ Owner = 'Custom owner'; Empty = '' }
    Invoke-OfflinePreProvision -Scenario $script:metadataScenario
    $snapshot = $global:maesterOfflineWrites.AUTOMATION_EXISTING_RUNBOOK_METADATA | ConvertFrom-Json -AsHashtable
    $snapshot.location | Should -BeExactly 'westus'
    $snapshot.properties.description | Should -BeExactly "Fresh 'quoted' Δ`nmetadata"
    $snapshot.properties.logProgress | Should -BeFalse
    $snapshot.properties.logVerbose | Should -BeTrue
    $snapshot.properties.logActivityTrace | Should -Be 3
    $snapshot.tags.Owner | Should -BeExactly 'Custom owner'
    $snapshot.tags.Empty | Should -BeExactly ''
    $calls = $global:maesterOfflineCalls -join '|'
    $calls | Should -Match 'runbooks/maester-runbook\?api-version=2024-10-23'
    $calls.IndexOf('AUTOMATION_EXISTING_RUNBOOK_METADATA') | Should -BeLessThan $calls.IndexOf('AUTOMATION_EXISTING_RESOURCES true')
    $calls | Should -Not -Match '--method (PUT|POST|PATCH|DELETE)'
  }

  It 'refreshes metadata on every provision instead of reusing the previous snapshot' {
    Invoke-OfflinePreProvision -Scenario $script:metadataScenario
    $script:metadataScenario.Values.AUTOMATION_EXISTING_RUNBOOK_METADATA = $global:maesterOfflineWrites.AUTOMATION_EXISTING_RUNBOOK_METADATA
    $script:metadataScenario.RunbookMetadata.properties.description = 'Changed between attempts'
    Invoke-OfflinePreProvision -Scenario $script:metadataScenario
    ($global:maesterOfflineWrites.AUTOMATION_EXISTING_RUNBOOK_METADATA | ConvertFrom-Json).properties.description | Should -BeExactly 'Changed between attempts'
  }

  It 'fails before any environment write on a failed fresh GET' {
    $script:metadataScenario.FailMetadataRead = $true
    { Invoke-OfflinePreProvision -Scenario $script:metadataScenario } | Should -Throw '*Could not inspect fresh runbook metadata*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|--method (PUT|POST|PATCH|DELETE)'
  }

  It 'fails before any environment write on <Label> metadata JSON' -ForEach @(
    @{ Label = 'empty'; Json = '' }, @{ Label = 'malformed'; Json = '{invalid' }, @{ Label = 'missing'; Json = '{}' }
  ) {
    $script:metadataScenario.RawMetadataRead = $Json
    { Invoke-OfflinePreProvision -Scenario $script:metadataScenario } | Should -Throw
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|--method (PUT|POST|PATCH|DELETE)'
  }

  It 'fails before any environment write when the exact read changed <Field>' -ForEach @(
    @{ Field = 'id'; Value = '/subscriptions/other/runbooks/maester-runbook' },
    @{ Field = 'type'; Value = 'Microsoft.Web/sites' }, @{ Field = 'state'; Value = 'Edit' },
    @{ Field = 'runbookType'; Value = 'Python3' }, @{ Field = 'logProgress'; Value = 'false' }
  ) {
    if ($Field -in @('id', 'type')) { $script:metadataScenario.RunbookMetadata[$Field] = $Value }
    else { $script:metadataScenario.RunbookMetadata.properties[$Field] = $Value }
    { Invoke-OfflinePreProvision -Scenario $script:metadataScenario } | Should -Throw '*fresh runbook metadata*'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set|--method (PUT|POST|PATCH|DELETE)'
  }

  It 'does not enable omission flags if persisting the verified snapshot is interrupted' {
    $script:metadataScenario.FailMetadataSet = $true
    { Invoke-OfflinePreProvision -Scenario $script:metadataScenario } | Should -Throw '*AUTOMATION_EXISTING_RUNBOOK_METADATA*'
    $global:maesterOfflineWrites.Count | Should -Be 0
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'env set -e test AUTOMATION_EXISTING_RESOURCES|--method (PUT|POST|PATCH|DELETE)'
  }

  It 'clears stale metadata on a verified fresh path without reading a runbook' {
    $fresh = New-OfflineScenario -GroupExists 'false'
    $fresh.Values.AUTOMATION_EXISTING_RUNBOOK_METADATA = '{"stale":true}'
    Invoke-OfflinePreProvision -Scenario $fresh
    $global:maesterOfflineWrites.AUTOMATION_EXISTING_RUNBOOK_METADATA | Should -BeExactly '{}'
    ($global:maesterOfflineCalls -join '|') | Should -Not -Match 'runbooks/maester-runbook\?'
  }

  It 'accepts an untagged fresh deployment on a later receipt-bound provision' {
    $fresh = New-OfflineScenario -GroupExists 'false'
    Invoke-OfflinePreProvision -Scenario $fresh
    $global:maesterOfflineWrites.AUTOMATION_EXISTING_RUNBOOK_METADATA | Should -BeExactly '{}'
    # Model the normal postdeployment receipt, without changing its ownership rules.
    $script:metadataScenario.RunbookMetadata.tags = $null
    Invoke-OfflinePreProvision -Scenario $script:metadataScenario
    $snapshot = $global:maesterOfflineWrites.AUTOMATION_EXISTING_RUNBOOK_METADATA | ConvertFrom-Json -AsHashtable
    $snapshot.Contains('tags') | Should -BeTrue
    $snapshot.tags | Should -BeNullOrEmpty
    $snapshot.properties.logProgress | Should -BeTrue
  }
}
