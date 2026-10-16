BeforeAll {
  . (Join-Path $PSScriptRoot '../scripts/PreservationMetadata.ps1')
  $script:controlNames = @('AUTOMATION_ADOPT_SOLUTION_TAG', 'AUTOMATION_UPGRADE_PRESERVE_ACCESS')
  $script:metadataAccountId = '/subscriptions/sub-test/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-test'
  $script:metadataPrincipalId = '11111111-1111-1111-1111-111111111111'
  $script:metadataJobId = '22222222-2222-2222-2222-222222222222'
  function New-PreservationValues {
    param([ValidateSet('OWNED', 'ADOPT')][string]$Kind = 'OWNED')
    @{
      AUTOMATION_ADOPT_SOLUTION_TAG = 'my-explicit-custom-solution'
      AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'true'
      "AUTOMATION_${Kind}_ACCOUNT_ID" = $script:metadataAccountId
      "AUTOMATION_${Kind}_PRINCIPAL_ID" = $script:metadataPrincipalId
      "AUTOMATION_${Kind}_JOB_SCHEDULE_ID" = $script:metadataJobId
    }
  }
  function Resolve-PreservationTag {
    param([System.Collections.IDictionary]$Values, [string]$Subscription = 'sub-test',
      [AllowEmptyString()][string]$Group = 'rg-test', [string]$Environment = 'test')
    Resolve-MaesterPreservationSolutionTag -EnvironmentValues $Values -SubscriptionId $Subscription `
      -ResourceGroupName $Group -EnvironmentName $Environment
  }
}

Describe 'Explicit preservation solution metadata' {
  BeforeEach {
    $script:savedControls = @{}
    foreach ($controlName in $script:controlNames) {
      $script:savedControls[$controlName] = [Environment]::GetEnvironmentVariable($controlName)
      Remove-Item -LiteralPath "Env:$controlName" -ErrorAction SilentlyContinue
    }
  }
  AfterEach {
    foreach ($controlName in $script:controlNames) {
      if ($null -eq $script:savedControls[$controlName]) {
        Remove-Item -LiteralPath "Env:$controlName" -ErrorAction SilentlyContinue
      }
      else {
        [Environment]::SetEnvironmentVariable($controlName, $script:savedControls[$controlName])
      }
    }
  }

  It 'keeps a fresh default canonical with an empty resource group' {
    Resolve-PreservationTag -Values @{} -Group '' | Should -BeExactly 'automation-account'
  }

  It 'keeps an explicitly empty tag canonical without adoption' {
    Resolve-PreservationTag -Values @{ AUTOMATION_ADOPT_SOLUTION_TAG = '' } | Should -BeExactly 'automation-account'
  }

  It 'does not infer a custom solution tag from unrelated environment metadata' {
    Resolve-PreservationTag -Values @{ solution = 'legacy'; SOLUTION_NAME = 'legacy'; AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'true' } |
      Should -BeExactly 'automation-account'
  }

  It 'accepts an arbitrary exact tag with a complete <Kind> triplet' -ForEach @(
    @{ Kind = 'OWNED' }, @{ Kind = 'ADOPT' }
  ) {
    $values = New-PreservationValues -Kind $Kind
    $values.AUTOMATION_ADOPT_SOLUTION_TAG = 'Team-specific Δ / not-an-alias = any text!'
    Resolve-PreservationTag -Values $values | Should -BeExactly $values.AUTOMATION_ADOPT_SOLUTION_TAG
  }

  It 'accepts a maximum-length exact custom tag without trimming or normalization' {
    $values = New-PreservationValues
    $values.AUTOMATION_ADOPT_SOLUTION_TAG = ' ' + ('x' * 254) + ' '
    Resolve-PreservationTag -Values $values | Should -BeExactly $values.AUTOMATION_ADOPT_SOLUTION_TAG
  }

  It 'treats an explicit canonical tag as an override requiring the same binding' {
    $values = @{ AUTOMATION_ADOPT_SOLUTION_TAG = 'automation-account'; AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'true' }
    { Resolve-PreservationTag -Values $values } | Should -Throw '*complete exact Automation ownership*'
  }

  It 'accepts matching complete receipt and adoption triplets plus the selected jobSchedule' {
    $values = New-PreservationValues
    foreach ($suffix in @('ACCOUNT_ID', 'PRINCIPAL_ID', 'JOB_SCHEDULE_ID')) {
      $values["AUTOMATION_ADOPT_$suffix"] = $values["AUTOMATION_OWNED_$suffix"]
    }
    $values.AUTOMATION_JOB_SCHEDULE_ID = $script:metadataJobId
    Resolve-PreservationTag -Values $values | Should -BeExactly $values.AUTOMATION_ADOPT_SOLUTION_TAG
  }

  It 'computes the account name using invariant lowercase and permits ARM ID casing' {
    $values = New-PreservationValues
    $values.AUTOMATION_OWNED_ACCOUNT_ID = $script:metadataAccountId.ToUpperInvariant()
    Resolve-PreservationTag -Values $values -Environment 'TEST' | Should -BeExactly $values.AUTOMATION_ADOPT_SOLUTION_TAG
  }

  It 'requires preserve=true for any explicit tag: <Control>' -ForEach @(
    @{ Control = '' }, @{ Control = 'false' }, @{ Control = $null }
  ) {
    $values = New-PreservationValues
    $values.AUTOMATION_UPGRADE_PRESERVE_ACCESS = $Control
    { Resolve-PreservationTag -Values $values } | Should -Throw '*requires AUTOMATION_UPGRADE_PRESERVE_ACCESS=true*'
  }

  It 'rejects malformed tag <Label>' -ForEach @(
    @{ Label = 'spaces'; Tag = '   ' }, @{ Label = 'newline'; Tag = "custom`nsolution" },
    @{ Label = 'tab'; Tag = "custom`tsolution" }, @{ Label = 'NUL'; Tag = "custom`0solution" },
    @{ Label = 'DEL'; Tag = ('custom' + [char]0x7f) }, @{ Label = 'line separator'; Tag = ('custom' + [char]0x2028) },
    @{ Label = 'overlong'; Tag = ('x' * 257) }, @{ Label = 'array'; Tag = @('custom', 'other') },
    @{ Label = 'boolean'; Tag = $true }
  ) {
    $values = New-PreservationValues
    $values.AUTOMATION_ADOPT_SOLUTION_TAG = $Tag
    { Resolve-PreservationTag -Values $values } | Should -Throw '*AUTOMATION_ADOPT_SOLUTION_TAG must be*'
  }

  It 'rejects malformed preserve value <Label>, including without custom metadata' -ForEach @(
    @{ Label = 'yes'; Value = 'yes' }, @{ Label = 'number'; Value = '1' },
    @{ Label = 'trailing space'; Value = 'true ' }, @{ Label = 'leading space'; Value = ' true' },
    @{ Label = 'spaces'; Value = ' ' }, @{ Label = 'newline'; Value = "true`n" },
    @{ Label = 'boolean'; Value = $true }, @{ Label = 'array'; Value = @('true', 'false') }
  ) {
    { Resolve-PreservationTag -Values @{ AUTOMATION_UPGRADE_PRESERVE_ACCESS = $Value } } |
      Should -Throw '*AUTOMATION_UPGRADE_PRESERVE_ACCESS must be*'
  }

  It 'rejects custom metadata backed only by the preservation flag' {
    { Resolve-PreservationTag -Values @{ AUTOMATION_ADOPT_SOLUTION_TAG = 'legacy'; AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'true' } } |
      Should -Throw '*complete exact Automation ownership*'
  }

  It 'rejects a partial <Kind> triplet missing <Suffix> even when the other triplet is complete' -ForEach @(
    @{ Kind = 'OWNED'; Other = 'ADOPT'; Suffix = 'ACCOUNT_ID' },
    @{ Kind = 'OWNED'; Other = 'ADOPT'; Suffix = 'PRINCIPAL_ID' },
    @{ Kind = 'OWNED'; Other = 'ADOPT'; Suffix = 'JOB_SCHEDULE_ID' },
    @{ Kind = 'ADOPT'; Other = 'OWNED'; Suffix = 'ACCOUNT_ID' },
    @{ Kind = 'ADOPT'; Other = 'OWNED'; Suffix = 'PRINCIPAL_ID' },
    @{ Kind = 'ADOPT'; Other = 'OWNED'; Suffix = 'JOB_SCHEDULE_ID' }
  ) {
    $values = New-PreservationValues -Kind $Other
    foreach ($part in @('ACCOUNT_ID', 'PRINCIPAL_ID', 'JOB_SCHEDULE_ID')) {
      if ($part -ne $Suffix) { $values["AUTOMATION_${Kind}_$part"] = $values["AUTOMATION_${Other}_$part"] }
    }
    { Resolve-PreservationTag -Values $values } | Should -Throw '*triplet is incomplete*'
  }

  It 'rejects an incorrect account scope or name: <Label>' -ForEach @(
    @{ Label = 'subscription'; Search = '/sub-test/'; Replace = '/other-sub/' },
    @{ Label = 'resource group'; Search = '/rg-test/'; Replace = '/other-rg/' },
    @{ Label = 'account'; Search = '/aa-test'; Replace = '/aa-other' },
    @{ Label = 'provider'; Search = 'Microsoft.Automation'; Replace = 'Microsoft.Other' },
    @{ Label = 'suffix'; Search = '/aa-test'; Replace = '/aa-test/jobSchedules/child' },
    @{ Label = 'trailing slash'; Search = '/aa-test'; Replace = '/aa-test/' }
  ) {
    $values = New-PreservationValues
    $values.AUTOMATION_OWNED_ACCOUNT_ID = $script:metadataAccountId.Replace($Search, $Replace)
    { Resolve-PreservationTag -Values $values } | Should -Throw '*exact Automation account scope*'
  }

  It 'rejects invalid GUIDs in <Kind> <Suffix>' -ForEach @(
    @{ Kind = 'OWNED'; Suffix = 'PRINCIPAL_ID' }, @{ Kind = 'OWNED'; Suffix = 'JOB_SCHEDULE_ID' },
    @{ Kind = 'ADOPT'; Suffix = 'PRINCIPAL_ID' }, @{ Kind = 'ADOPT'; Suffix = 'JOB_SCHEDULE_ID' }
  ) {
    $values = New-PreservationValues -Kind $Kind
    $values["AUTOMATION_${Kind}_$Suffix"] = 'not-a-guid'
    { Resolve-PreservationTag -Values $values } | Should -Throw '*valid principal/jobSchedule GUIDs*'
  }

  It 'rejects non-string values in <Kind> <Suffix>' -ForEach @(
    @{ Kind = 'OWNED'; Suffix = 'ACCOUNT_ID' }, @{ Kind = 'OWNED'; Suffix = 'PRINCIPAL_ID' },
    @{ Kind = 'OWNED'; Suffix = 'JOB_SCHEDULE_ID' }, @{ Kind = 'ADOPT'; Suffix = 'ACCOUNT_ID' },
    @{ Kind = 'ADOPT'; Suffix = 'PRINCIPAL_ID' }, @{ Kind = 'ADOPT'; Suffix = 'JOB_SCHEDULE_ID' }
  ) {
    $values = New-PreservationValues -Kind $Kind
    $values["AUTOMATION_${Kind}_$Suffix"] = @($values["AUTOMATION_${Kind}_$Suffix"])
    { Resolve-PreservationTag -Values $values } | Should -Throw "*AUTOMATION_${Kind}_$Suffix must be a string value*"
  }

  It 'rejects whitespace or control characters in otherwise parseable receipt GUIDs' -ForEach @(
    @{ Value = ' 11111111-1111-1111-1111-111111111111' },
    @{ Value = "11111111-1111-1111-1111-111111111111`n" }
  ) {
    $values = New-PreservationValues
    $values.AUTOMATION_OWNED_PRINCIPAL_ID = $Value
    { Resolve-PreservationTag -Values $values } | Should -Throw '*valid principal/jobSchedule GUIDs*'
  }

  It 'rejects mismatching complete adoption <Suffix>' -ForEach @(
    @{ Suffix = 'ACCOUNT_ID'; Replacement = '/subscriptions/sub-test/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-other' },
    @{ Suffix = 'PRINCIPAL_ID'; Replacement = '33333333-3333-3333-3333-333333333333' },
    @{ Suffix = 'JOB_SCHEDULE_ID'; Replacement = '33333333-3333-3333-3333-333333333333' }
  ) {
    $values = New-PreservationValues
    foreach ($part in @('ACCOUNT_ID', 'PRINCIPAL_ID', 'JOB_SCHEDULE_ID')) { $values["AUTOMATION_ADOPT_$part"] = $values["AUTOMATION_OWNED_$part"] }
    $values["AUTOMATION_ADOPT_$Suffix"] = $Replacement
    { Resolve-PreservationTag -Values $values } | Should -Throw
  }

  It 'rejects a selected jobSchedule that disagrees with the binding: <Label>' -ForEach @(
    @{ Label = 'different GUID'; Value = '33333333-3333-3333-3333-333333333333' },
    @{ Label = 'invalid GUID'; Value = 'not-a-guid' }, @{ Label = 'empty'; Value = '' },
    @{ Label = 'null'; Value = $null }, @{ Label = 'array'; Value = @('22222222-2222-2222-2222-222222222222') }
  ) {
    $values = New-PreservationValues
    $values.AUTOMATION_JOB_SCHEDULE_ID = $Value
    { Resolve-PreservationTag -Values $values } | Should -Throw '*AUTOMATION_JOB_SCHEDULE_ID differs*'
  }

  It 'rejects invalid explicit scope <Label>' -ForEach @(
    @{ Label = 'empty group'; Subscription = 'sub-test'; Group = ''; Environment = 'test' },
    @{ Label = 'empty subscription'; Subscription = ''; Group = 'rg-test'; Environment = 'test' },
    @{ Label = 'empty environment'; Subscription = 'sub-test'; Group = 'rg-test'; Environment = '' },
    @{ Label = 'group path'; Subscription = 'sub-test'; Group = 'rg-test/extra'; Environment = 'test' },
    @{ Label = 'subscription query'; Subscription = 'sub-test?query'; Group = 'rg-test'; Environment = 'test' },
    @{ Label = 'environment newline'; Subscription = 'sub-test'; Group = 'rg-test'; Environment = "test`n" },
    @{ Label = 'group whitespace'; Subscription = 'sub-test'; Group = ' rg-test'; Environment = 'test' }
  ) {
    { Resolve-PreservationTag -Values (New-PreservationValues) -Subscription $Subscription -Group $Group -Environment $Environment } |
      Should -Throw '*exact subscription, resource group, and environment scope*'
  }

  It 'accepts process controls only with a complete selected-environment binding' {
    $values = New-PreservationValues
    $values.Remove('AUTOMATION_ADOPT_SOLUTION_TAG')
    $values.Remove('AUTOMATION_UPGRADE_PRESERVE_ACCESS')
    $env:AUTOMATION_ADOPT_SOLUTION_TAG = 'Explicit process tag'
    $env:AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'TRUE'
    Resolve-PreservationTag -Values $values | Should -BeExactly 'Explicit process tag'
  }

  It 'does not assemble an ownership receipt from process variables' {
    $values = New-PreservationValues
    $savedBindings = @{}
    try {
      foreach ($suffix in @('ACCOUNT_ID', 'PRINCIPAL_ID', 'JOB_SCHEDULE_ID')) {
        $bindingName = "AUTOMATION_OWNED_$suffix"
        $savedBindings[$bindingName] = [Environment]::GetEnvironmentVariable($bindingName)
        [Environment]::SetEnvironmentVariable($bindingName, $values[$bindingName])
        $values.Remove($bindingName)
      }
      { Resolve-PreservationTag -Values $values } | Should -Throw '*complete exact Automation ownership*'
    }
    finally {
      foreach ($bindingName in $savedBindings.Keys) {
        if ($null -eq $savedBindings[$bindingName]) {
          Remove-Item -LiteralPath "Env:$bindingName" -ErrorAction SilentlyContinue
        }
        else { [Environment]::SetEnvironmentVariable($bindingName, $savedBindings[$bindingName]) }
      }
    }
  }

  It 'rejects a process/selected tag mismatch including case only' -ForEach @(
    @{ Process = 'other-solution' }, @{ Process = 'MY-EXPLICIT-CUSTOM-SOLUTION' }
  ) {
    $env:AUTOMATION_ADOPT_SOLUTION_TAG = $Process
    { Resolve-PreservationTag -Values (New-PreservationValues) } | Should -Throw '*process AUTOMATION_ADOPT_SOLUTION_TAG differs*'
  }

  It 'rejects a process override of an explicitly empty selected tag' {
    $env:AUTOMATION_ADOPT_SOLUTION_TAG = 'custom'
    { Resolve-PreservationTag -Values @{ AUTOMATION_ADOPT_SOLUTION_TAG = '' } } | Should -Throw '*process AUTOMATION_ADOPT_SOLUTION_TAG differs*'
  }

  It 'rejects a process/selected preservation mismatch' {
    $env:AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'false'
    { Resolve-PreservationTag -Values (New-PreservationValues) } | Should -Throw '*process AUTOMATION_UPGRADE_PRESERVE_ACCESS differs*'
  }

  It 'accepts equivalent boolean case and exact process/selected tags' {
    $values = New-PreservationValues
    $env:AUTOMATION_ADOPT_SOLUTION_TAG = $values.AUTOMATION_ADOPT_SOLUTION_TAG
    $env:AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'TRUE'
    Resolve-PreservationTag -Values $values | Should -BeExactly $values.AUTOMATION_ADOPT_SOLUTION_TAG
  }

  It 'validates malformed process controls even when selected values are present' -ForEach @(
    @{ Name = 'AUTOMATION_ADOPT_SOLUTION_TAG'; Value = "tag`nvalue" },
    @{ Name = 'AUTOMATION_UPGRADE_PRESERVE_ACCESS'; Value = 'yes' }
  ) {
    [Environment]::SetEnvironmentVariable($Name, $Value)
    { Resolve-PreservationTag -Values (New-PreservationValues) } | Should -Throw "*$Name must be*"
  }

  It 'uses the canonical process control name when a caller varies parameter casing' {
    $env:AUTOMATION_UPGRADE_PRESERVE_ACCESS = 'true'
    Resolve-MaesterUpgradeControlValue -EnvironmentValues @{} -Name 'automation_upgrade_preserve_access' | Should -BeExactly 'true'
  }

  It 'does not write metadata, synthesize a receipt, or call an external tool' {
    $values = New-PreservationValues -Kind ADOPT
    $before = $values | ConvertTo-Json -Depth 10 -Compress
    function az { throw 'No Azure call is permitted.' }
    function azd { throw 'No azd call is permitted.' }
    Resolve-PreservationTag -Values $values | Should -BeExactly $values.AUTOMATION_ADOPT_SOLUTION_TAG
    ($values | ConvertTo-Json -Depth 10 -Compress) | Should -BeExactly $before
    $values.ContainsKey('AUTOMATION_OWNED_ACCOUNT_ID') | Should -BeFalse
    [Environment]::GetEnvironmentVariable('AUTOMATION_ADOPT_SOLUTION_TAG') | Should -BeNullOrEmpty
  }
}
