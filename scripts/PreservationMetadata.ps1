#Requires -Version 7.6
function Resolve-MaesterUpgradeControlValue {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentValues,
    [Parameter(Mandatory)]
    [ValidateSet('AUTOMATION_ADOPT_SOLUTION_TAG', 'AUTOMATION_UPGRADE_PRESERVE_ACCESS')]
    [string]$Name
  )

  $Name = $Name.ToUpperInvariant()
  $hasSelected = $EnvironmentValues.Contains($Name)
  $selected = if ($hasSelected) { $EnvironmentValues[$Name] } else { $null }
  $process = [Environment]::GetEnvironmentVariable($Name)
  if ($null -ne $selected -and $selected -isnot [string]) {
    throw "$Name must be a string value."
  }
  $isTag = $Name -eq 'AUTOMATION_ADOPT_SOLUTION_TAG'
  foreach ($value in @($selected, $process)) {
    if ($null -eq $value -or $value -ceq '') { continue }
    if ($isTag) {
      if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 256 -or
          $value -match '[\p{Cc}\p{Zl}\p{Zp}]') {
        throw 'AUTOMATION_ADOPT_SOLUTION_TAG must be a nonblank tag value of at most 256 characters without control characters.'
      }
    }
    elseif ($value -notin @('true', 'false')) {
      throw "$Name must be true or false."
    }
  }
  if ($hasSelected -and $null -ne $process) {
    $comparison = if ($isTag) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
    if (-not [string]::Equals([string]$selected, $process, $comparison)) {
      throw "The process $Name differs from the selected azd environment."
    }
  }
  if ($hasSelected) { return [string]$selected }
  return [string]$process
}

function Resolve-MaesterPreservationSolutionTag {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentValues,
    [Parameter(Mandatory)][AllowEmptyString()][string]$SubscriptionId,
    [Parameter(Mandatory)][AllowEmptyString()][string]$ResourceGroupName,
    [Parameter(Mandatory)][AllowEmptyString()][string]$EnvironmentName
  )

  # This selects an explicitly expected tag only. Live account, principal, and
  # jobSchedule verification is still required before any deployment mutation.
  # Neither metadata nor an ownership receipt is inferred, created, or changed.
  $tag = Resolve-MaesterUpgradeControlValue -EnvironmentValues $EnvironmentValues -Name 'AUTOMATION_ADOPT_SOLUTION_TAG'
  $preserve = Resolve-MaesterUpgradeControlValue -EnvironmentValues $EnvironmentValues -Name 'AUTOMATION_UPGRADE_PRESERVE_ACCESS'
  if ($tag -ceq '') { return 'automation-account' }
  if ($preserve -ine 'true') {
    throw 'AUTOMATION_ADOPT_SOLUTION_TAG requires AUTOMATION_UPGRADE_PRESERVE_ACCESS=true.'
  }

  foreach ($part in @($SubscriptionId, $ResourceGroupName, $EnvironmentName)) {
    if ([string]::IsNullOrWhiteSpace($part) -or $part -cne $part.Trim() -or $part -match '[/\\?#\p{Cc}\p{Zl}\p{Zp}]') {
      throw 'Custom solution tag preservation requires an exact subscription, resource group, and environment scope.'
    }
  }
  $expectedAccountId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/aa-$($EnvironmentName.ToLowerInvariant())"
  $binding = $null
  foreach ($kind in @('OWNED', 'ADOPT')) {
    $parts = @('ACCOUNT_ID', 'PRINCIPAL_ID', 'JOB_SCHEDULE_ID') | ForEach-Object {
      $name = "AUTOMATION_${kind}_$_"
      $value = $EnvironmentValues[$name]
      if ($null -ne $value -and $value -isnot [string]) { throw "$name must be a string value." }
      [string]$value
    }
    $present = @($parts | Where-Object { $_ -cne '' })
    if ($present.Count -eq 0) { continue }
    if ($present.Count -ne 3) {
      throw "The AUTOMATION_$kind ownership triplet is incomplete for custom solution tag preservation."
    }
    $principal = [guid]::Empty
    $jobSchedule = [guid]::Empty
    if ($parts[0] -ine $expectedAccountId -or
        -not [guid]::TryParse($parts[1], [ref]$principal) -or
        -not [guid]::TryParse($parts[2], [ref]$jobSchedule) -or
        @($parts | Where-Object { $_ -cne $_.Trim() -or $_ -match '[\p{Cc}\p{Zl}\p{Zp}]' }).Count -gt 0) {
      throw "The AUTOMATION_$kind ownership triplet does not match the exact Automation account scope or valid principal/jobSchedule GUIDs."
    }
    if ($null -ne $binding -and
        ($binding[0] -ine $parts[0] -or $binding[1] -ine $parts[1] -or $binding[2] -ine $parts[2])) {
      throw 'The explicit Automation adoption request conflicts with the ownership receipt.'
    }
    $binding = $parts
  }
  if ($null -eq $binding) {
    throw 'Custom solution tag preservation requires a complete exact Automation ownership receipt or explicit adoption triplet.'
  }
  if ($EnvironmentValues.Contains('AUTOMATION_JOB_SCHEDULE_ID') -and
      ($EnvironmentValues['AUTOMATION_JOB_SCHEDULE_ID'] -isnot [string] -or
       [string]$EnvironmentValues['AUTOMATION_JOB_SCHEDULE_ID'] -ine $binding[2])) {
    throw 'AUTOMATION_JOB_SCHEDULE_ID differs from the custom solution tag preservation ownership binding.'
  }
  return $tag
}
