BeforeAll {
  . (Join-Path $PSScriptRoot '../scripts/JobScheduleOwnership.ps1')
  $script:accountId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-test'
  $script:principalId = '33333333-3333-4333-8333-333333333333'
  $script:jobId = '22222222-2222-4222-8222-222222222222'
  $script:replacementId = '44444444-4444-4444-8444-444444444444'
  # GET and list examples return id and properties without requiring name/type:
  # https://learn.microsoft.com/en-us/rest/api/automation/job-schedule/get?view=rest-automation-2024-10-23
  # https://learn.microsoft.com/en-us/rest/api/automation/job-schedule/list-by-automation-account?view=rest-automation-2024-10-23
  $script:rawServiceJson = @'
{
  "id": "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-test/jobSchedules/22222222-2222-4222-8222-222222222222",
  "properties": {
    "jobScheduleId": "22222222-2222-4222-8222-222222222222",
    "runbook": { "name": "maester-runbook" },
    "schedule": { "name": "maester-weekly-sunday" },
    "parameters": { "IncludeAzure": "false", "ExistingParameter": "retained" },
    "runOn": "existing-hybrid-worker"
  }
}
'@
  $script:resourceShapedJson = @'
{
  "id": "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-test/jobSchedules/22222222-2222-4222-8222-222222222222",
  "name": "22222222-2222-4222-8222-222222222222",
  "type": "Microsoft.Automation/AutomationAccounts/JobSchedules",
  "properties": {
    "jobScheduleId": "22222222-2222-4222-8222-222222222222",
    "runbook": { "name": "maester-runbook" },
    "schedule": { "name": "maester-weekly-sunday" },
    "parameters": { "IncludeAzure": "false", "ExistingParameter": "retained" },
    "runOn": "existing-hybrid-worker"
  }
}
'@
  $script:account = [pscustomobject]@{ id = $script:accountId; identity = @{ principalId = $script:principalId } }
  $script:receipt = @{
    ReceiptAccountId = $script:accountId
    ReceiptPrincipalId = $script:principalId
    ReceiptJobScheduleId = $script:jobId
  }
}

Describe 'Azure Automation jobSchedule response identity' {
  It 'accepts <Shape> JSON under StrictMode without adding fields or changing serialized input bytes' -ForEach @(
    @{ Shape = 'raw service PSCustomObject'; WithOptionalMetadata = $false; Dictionary = $false },
    @{ Shape = 'resource shaped PSCustomObject'; WithOptionalMetadata = $true; Dictionary = $false },
    @{ Shape = 'raw service dictionary'; WithOptionalMetadata = $false; Dictionary = $true },
    @{ Shape = 'resource shaped dictionary'; WithOptionalMetadata = $true; Dictionary = $true }
  ) {
    Set-StrictMode -Version Latest
    $json = if ($WithOptionalMetadata) { $script:resourceShapedJson } else { $script:rawServiceJson }
    $job = if ($Dictionary) { $json | ConvertFrom-Json -AsHashtable } else { $json | ConvertFrom-Json }
    $before = $job | ConvertTo-Json -Depth 30 -Compress
    $beforeBytes = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($before))
    $beforeProperties = if ($Dictionary) { $job.Keys -join '|' } else { $job.PSObject.Properties.Name -join '|' }
    $beforeNestedProperties = if ($Dictionary) { $job.properties.Keys -join '|' } else { $job.properties.PSObject.Properties.Name -join '|' }

    { Assert-MaesterJobScheduleIdentity -ExpectedAccountId $script:accountId -ExpectedJobScheduleId $script:jobId -JobSchedule $job } | Should -Not -Throw

    $after = $job | ConvertTo-Json -Depth 30 -Compress
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($after)) | Should -BeExactly $beforeBytes
    $afterProperties = if ($Dictionary) { $job.Keys -join '|' } else { $job.PSObject.Properties.Name -join '|' }
    $afterNestedProperties = if ($Dictionary) { $job.properties.Keys -join '|' } else { $job.properties.PSObject.Properties.Name -join '|' }
    $afterProperties | Should -BeExactly $beforeProperties
    $afterNestedProperties | Should -BeExactly $beforeNestedProperties
    $job.properties.parameters.ExistingParameter | Should -BeExactly 'retained'
    $job.properties.runOn | Should -BeExactly 'existing-hybrid-worker'
    if (-not $WithOptionalMetadata) {
      if ($Dictionary) {
        $job.Contains('name') | Should -BeFalse
        $job.Contains('type') | Should -BeFalse
      }
      else {
        $job.PSObject.Properties['name'] | Should -BeNullOrEmpty
        $job.PSObject.Properties['type'] | Should -BeNullOrEmpty
      }
    }
  }

  It 'rejects a supplied <Field> that disagrees with the selected identity: <Label>' -ForEach @(
    @{ Field = 'name'; Label = 'different GUID'; Value = '44444444-4444-4444-8444-444444444444' },
    @{ Field = 'name'; Label = 'empty'; Value = '' },
    @{ Field = 'name'; Label = 'null'; Value = $null },
    @{ Field = 'type'; Label = 'different resource type'; Value = 'Microsoft.Automation/automationAccounts/schedules' },
    @{ Field = 'type'; Label = 'empty'; Value = '' },
    @{ Field = 'type'; Label = 'null'; Value = $null }
  ) {
    Set-StrictMode -Version Latest
    $job = $script:resourceShapedJson | ConvertFrom-Json
    $job.$Field = $Value
    { Assert-MaesterJobScheduleIdentity -ExpectedAccountId $script:accountId -ExpectedJobScheduleId $script:jobId -JobSchedule $job } | Should -Throw
  }

  It 'requires properties.jobScheduleId even when optional name agrees: <Label>' -ForEach @(
    @{ Label = 'missing'; Remove = $true; Value = $null },
    @{ Label = 'null'; Remove = $false; Value = $null },
    @{ Label = 'empty'; Remove = $false; Value = '' },
    @{ Label = 'not a GUID'; Remove = $false; Value = 'maester-weekly-sunday' },
    @{ Label = 'different GUID'; Remove = $false; Value = '44444444-4444-4444-8444-444444444444' }
  ) {
    Set-StrictMode -Version Latest
    $job = $script:resourceShapedJson | ConvertFrom-Json
    if ($Remove) { $job.properties.PSObject.Properties.Remove('jobScheduleId') }
    else { $job.properties.jobScheduleId = $Value }
    { Assert-MaesterJobScheduleIdentity -ExpectedAccountId $script:accountId -ExpectedJobScheduleId $script:jobId -JobSchedule $job } | Should -Throw
  }

  It 'requires the exact full selected account/jobSchedules/GUID id: <Label>' -ForEach @(
    @{ Label = 'missing'; Remove = $true; Id = $null },
    @{ Label = 'empty'; Remove = $false; Id = '' },
    @{ Label = 'bare GUID'; Remove = $false; Id = '22222222-2222-4222-8222-222222222222' },
    @{ Label = 'different subscription'; Remove = $false; Id = '/subscriptions/other/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-test/jobSchedules/22222222-2222-4222-8222-222222222222' },
    @{ Label = 'different resource group'; Remove = $false; Id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/other/providers/Microsoft.Automation/automationAccounts/aa-test/jobSchedules/22222222-2222-4222-8222-222222222222' },
    @{ Label = 'different parent account'; Remove = $false; Id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/other/jobSchedules/22222222-2222-4222-8222-222222222222' },
    @{ Label = 'wrong child path'; Remove = $false; Id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-test/schedules/22222222-2222-4222-8222-222222222222' },
    @{ Label = 'different GUID'; Remove = $false; Id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-test/jobSchedules/44444444-4444-4444-8444-444444444444' },
    @{ Label = 'extra child suffix'; Remove = $false; Id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-test/jobSchedules/22222222-2222-4222-8222-222222222222/extra' }
  ) {
    Set-StrictMode -Version Latest
    $job = $script:rawServiceJson | ConvertFrom-Json
    if ($Remove) { $job.PSObject.Properties.Remove('id') }
    else { $job.id = $Id }
    { Assert-MaesterJobScheduleIdentity -ExpectedAccountId $script:accountId -ExpectedJobScheduleId $script:jobId -JobSchedule $job } | Should -Throw
  }

  It 'retains receipt-bound raw associations through the existing ownership helpers under StrictMode' {
    Set-StrictMode -Version Latest
    $job = $script:rawServiceJson | ConvertFrom-Json
    $before = $job | ConvertTo-Json -Depth 30 -Compress
    $ownership = Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account -JobSchedules @($job) @script:receipt
    $ownership.JobScheduleId | Should -BeExactly $script:jobId
    $ownership.OwnedJobScheduleId | Should -BeExactly $script:jobId
    { Assert-MaesterJobScheduleWriteTarget -ExpectedAccountId $script:accountId -ExpectedPrincipalId $script:principalId -JobScheduleId $script:jobId -Account $script:account -JobSchedules @($job) @script:receipt } | Should -Not -Throw
    { Assert-MaesterOwnershipReceiptTarget -ExpectedAccountId $script:accountId -ExpectedPrincipalId $script:principalId -ExpectedJobScheduleId $script:jobId -Account $script:account -JobSchedule $job } | Should -Not -Throw
    ($job | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
  }

  It 'rejects duplicate raw associations through both inventory ownership helpers' {
    Set-StrictMode -Version Latest
    $job = $script:rawServiceJson | ConvertFrom-Json
    $duplicate = $script:rawServiceJson | ConvertFrom-Json
    { Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account -JobSchedules @($job, $duplicate) @script:receipt } | Should -Throw '*More than one*'
    { Assert-MaesterJobScheduleWriteTarget -ExpectedAccountId $script:accountId -ExpectedPrincipalId $script:principalId -JobScheduleId $script:jobId -Account $script:account -JobSchedules @($job, $duplicate) @script:receipt } | Should -Throw '*ambiguous*'
  }

  It 'rejects a replacement GUID for the same schedule/runbook pair instead of rotating the saved receipt' {
    Set-StrictMode -Version Latest
    $job = $script:rawServiceJson | ConvertFrom-Json
    $job.id = "$($script:accountId)/jobSchedules/$($script:replacementId)"
    $job.properties.jobScheduleId = $script:replacementId
    $beforeReceipt = $script:receipt | ConvertTo-Json -Compress
    { Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $script:accountId -Account $script:account -JobSchedules @($job) @script:receipt } | Should -Throw
    { Assert-MaesterJobScheduleWriteTarget -ExpectedAccountId $script:accountId -ExpectedPrincipalId $script:principalId -JobScheduleId $script:jobId -Account $script:account -JobSchedules @($job) @script:receipt } | Should -Throw
    { Assert-MaesterOwnershipReceiptTarget -ExpectedAccountId $script:accountId -ExpectedPrincipalId $script:principalId -ExpectedJobScheduleId $script:jobId -Account $script:account -JobSchedule $job } | Should -Throw
    ($script:receipt | ConvertTo-Json -Compress) | Should -BeExactly $beforeReceipt
  }
}
