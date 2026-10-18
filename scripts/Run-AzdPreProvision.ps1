#Requires -Version 7.6
[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Resolve-DeploymentTargets.ps1')
. (Join-Path $PSScriptRoot 'JobScheduleOwnership.ps1')

$EnvironmentName = if ($env:AZURE_ENV_NAME) { $env:AZURE_ENV_NAME } else { '' }
if ([string]::IsNullOrWhiteSpace($EnvironmentName)) { throw 'AZURE_ENV_NAME must identify the selected azd environment.' }
$ambientValues = Assert-MaesterAzdEnvironmentContext -EnvironmentName $EnvironmentName
if (($SubscriptionId -and $ambientValues['AZURE_SUBSCRIPTION_ID'] -ine $SubscriptionId) -or
    ($env:AZURE_SUBSCRIPTION_ID -and $ambientValues['AZURE_SUBSCRIPTION_ID'] -ine $env:AZURE_SUBSCRIPTION_ID) -or
    ($TenantId -and $ambientValues['AZURE_TENANT_ID'] -ine $TenantId) -or
    ($env:AZURE_TENANT_ID -and $ambientValues['AZURE_TENANT_ID'] -ine $env:AZURE_TENANT_ID)) {
  throw 'The process Azure target differs from the selected azd environment.'
}

Import-Module (Join-Path $PSScriptRoot 'vendor\Azd.MaesterHooks\Maester-PreProvision.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'vendor\Azd.MaesterHooks\Maester-Helpers.psm1') -Force

if (-not $SubscriptionId) { $SubscriptionId = [string]$ambientValues['AZURE_SUBSCRIPTION_ID'] }
if (-not $TenantId) { $TenantId = [string]$ambientValues['AZURE_TENANT_ID'] }
if ([string]::IsNullOrWhiteSpace($TenantId)) { throw 'The selected azd environment must specify AZURE_TENANT_ID.' }
Import-Module (Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Maester-SetupHelpers.psm1') -Force
Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null

$location = $env:AZURE_LOCATION
Invoke-MaesterPreProvision `
  -SolutionName 'automation-account' `
  -SubscriptionId $SubscriptionId `
  -TenantId $TenantId `
  -Location $location

Assert-MaesterAzdEnvironmentContext -EnvironmentName $EnvironmentName | Out-Null
$selectedValues = & azd env get-values -e $EnvironmentName --output json | ConvertFrom-Json -AsHashtable
if ($LASTEXITCODE -ne 0 -or -not $selectedValues -or $selectedValues['AZURE_ENV_NAME'] -ine $EnvironmentName) {
  throw 'Could not verify the selected azd environment after the preprovision wizard.'
}
if (($env:AZURE_SUBSCRIPTION_ID -and $selectedValues['AZURE_SUBSCRIPTION_ID'] -ine $env:AZURE_SUBSCRIPTION_ID) -or
    ($env:AZURE_TENANT_ID -and $selectedValues['AZURE_TENANT_ID'] -ine $env:AZURE_TENANT_ID) -or
    ($TenantId -and $selectedValues['AZURE_TENANT_ID'] -ine $TenantId)) {
  throw 'The preprovision wizard selected a different Azure target.'
}
if (-not $SubscriptionId) { $SubscriptionId = [string]$selectedValues['AZURE_SUBSCRIPTION_ID'] }
$rgName = [string]$selectedValues['AZURE_RESOURCE_GROUP']
if ([string]::IsNullOrWhiteSpace($SubscriptionId) -or $selectedValues['AZURE_SUBSCRIPTION_ID'] -ine $SubscriptionId) {
  throw 'The selected azd environment has no matching subscription.'
}
if ([string]::IsNullOrWhiteSpace($location)) { $location = [string]$selectedValues['AZURE_LOCATION'] }
$aaName = "aa-$($EnvironmentName.ToLower())"
$expectedSolutionTag = Resolve-MaesterPreservationSolutionTag -EnvironmentValues $selectedValues -SubscriptionId $SubscriptionId `
  -ResourceGroupName $rgName -EnvironmentName $EnvironmentName
$explicitSolutionTag = Resolve-MaesterUpgradeControlValue -EnvironmentValues $selectedValues -Name 'AUTOMATION_ADOPT_SOLUTION_TAG'
$solutionTagComparer = if (-not [string]::IsNullOrEmpty($explicitSolutionTag)) { [StringComparer]::Ordinal } else { [StringComparer]::OrdinalIgnoreCase }

$priorOwnership = @(@('AUTOMATION_OWNED_ACCOUNT_ID', 'AUTOMATION_OWNED_PRINCIPAL_ID', 'AUTOMATION_OWNED_JOB_SCHEDULE_ID',
  'AUTOMATION_ADOPT_ACCOUNT_ID', 'AUTOMATION_ADOPT_PRINCIPAL_ID', 'AUTOMATION_ADOPT_JOB_SCHEDULE_ID') |
  Where-Object { -not [string]::IsNullOrWhiteSpace([string]$selectedValues[$_]) })
$resourceGroupExists = $false
if (-not [string]::IsNullOrWhiteSpace($rgName)) {
  $existsResult = & az group exists --name $rgName --subscription $SubscriptionId -o tsv
  if ($LASTEXITCODE -ne 0 -or [string]$existsResult -notin @('true', 'false')) {
    throw 'Could not verify whether the target resource group exists.'
  }
  $resourceGroupExists = [string]$existsResult -eq 'true'
}
if (-not $resourceGroupExists -and $priorOwnership.Count -gt 0) {
  throw 'An Automation ownership receipt or adoption request exists, but its target resource group is absent.'
}
$expectedAccountId = if ($resourceGroupExists) {
  "/subscriptions/$SubscriptionId/resourceGroups/$rgName/providers/Microsoft.Automation/automationAccounts/$aaName"
} else { '' }

# Read the complete inventory before deciding whether an exact prior association can be reused.
$account = $null
$jobSchedules = @()
if ($resourceGroupExists) {
  $accountListUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$rgName/providers/Microsoft.Automation/automationAccounts?api-version=2023-11-01"
  $accountListJson = & az rest --method GET --uri $accountListUri --subscription $SubscriptionId -o json
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accountListJson)) { throw 'Could not inspect Automation accounts in the target resource group.' }
  $accountList = $accountListJson | ConvertFrom-Json -ErrorAction Stop
  if ($null -eq $accountList.value -or $accountList.value -isnot [System.Collections.IList] -or
      ($accountList.PSObject.Properties['nextLink'] -and $accountList.nextLink)) {
    throw 'Automation account inventory was incomplete.'
  }
  $matchingAccounts = @($accountList.value | Where-Object { $_.name -ieq $aaName })
  if ($matchingAccounts.Count -gt 1) { throw 'Automation account inventory has duplicate target names.' }
}
if ($resourceGroupExists -and $matchingAccounts.Count -eq 1) {
  $accountJson = & az rest --method GET --uri "https://management.azure.com$expectedAccountId`?api-version=2023-11-01" --subscription $SubscriptionId -o json
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accountJson)) { throw 'Could not inspect the exact Automation account.' }
  $account = $accountJson | ConvertFrom-Json -ErrorAction Stop
  if ($account.id -ine $expectedAccountId -or $account.name -ine $aaName -or
      $account.type -ine 'Microsoft.Automation/automationAccounts' -or
      -not $account.tags -or $account.tags.workload -ine 'maester' -or
      -not $solutionTagComparer.Equals([string]$account.tags.solution, $expectedSolutionTag) -or
      $account.tags.environment -ine $EnvironmentName -or $account.tags.managedBy -ine 'azd') {
    throw 'The exact Automation account does not match the template deployment target.'
  }
  $schedulesUri = "https://management.azure.com$expectedAccountId/jobSchedules?api-version=2023-11-01"
  $schedulesJson = & az rest --method GET --uri $schedulesUri --subscription $SubscriptionId -o json
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($schedulesJson)) { throw 'Could not inspect live Automation jobSchedules.' }
  $schedulesResponse = $schedulesJson | ConvertFrom-Json -ErrorAction Stop
  if ($null -eq $schedulesResponse.value -or $schedulesResponse.value -isnot [System.Collections.IList] -or
      ($schedulesResponse.PSObject.Properties['nextLink'] -and $schedulesResponse.nextLink)) {
    throw 'Automation jobSchedule inventory was incomplete.'
  }
  $jobSchedules = @($schedulesResponse.value)
}

$ownership = if ($resourceGroupExists) {
  Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $expectedAccountId -Account $account -JobSchedules $jobSchedules `
    -ReceiptAccountId ([string]$selectedValues['AUTOMATION_OWNED_ACCOUNT_ID']) `
    -ReceiptPrincipalId ([string]$selectedValues['AUTOMATION_OWNED_PRINCIPAL_ID']) `
    -ReceiptJobScheduleId ([string]$selectedValues['AUTOMATION_OWNED_JOB_SCHEDULE_ID']) `
    -AdoptAccountId ([string]$selectedValues['AUTOMATION_ADOPT_ACCOUNT_ID']) `
    -AdoptPrincipalId ([string]$selectedValues['AUTOMATION_ADOPT_PRINCIPAL_ID']) `
    -AdoptJobScheduleId ([string]$selectedValues['AUTOMATION_ADOPT_JOB_SCHEDULE_ID'])
} else {
  [pscustomobject]@{ JobScheduleId = [guid]::NewGuid().ToString(); OwnedJobScheduleId = '' }
}

# Existing/fresh decisions are refreshed from Azure on every provision. Never trust
# a persisted omission flag after a failed or interrupted deployment.
foreach ($controlName in @('AUTOMATION_UPGRADE_PRESERVE_ACCESS', 'AUTOMATION_EXISTING_RESOURCES', 'AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION')) {
  $processValue = [Environment]::GetEnvironmentVariable($controlName)
  $selectedValue = [string]$selectedValues[$controlName]
  if (-not [string]::IsNullOrWhiteSpace($processValue) -and -not [string]::IsNullOrWhiteSpace($selectedValue) -and
      (Get-MaesterUpgradeBoolean -Value $processValue -Name $controlName) -ne (Get-MaesterUpgradeBoolean -Value $selectedValue -Name $controlName)) {
    throw "The process $controlName differs from the selected azd environment."
  }
}
$preserveUpgradeAccess = Get-MaesterUpgradeBoolean -Name 'AUTOMATION_UPGRADE_PRESERVE_ACCESS' `
  -Value $(if ($selectedValues['AUTOMATION_UPGRADE_PRESERVE_ACCESS']) { [string]$selectedValues['AUTOMATION_UPGRADE_PRESERVE_ACCESS'] } else { [string]$env:AUTOMATION_UPGRADE_PRESERVE_ACCESS })
$validationControl = if ($selectedValues['AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION']) {
  [string]$selectedValues['AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION']
} else { [string]$env:AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION }
Get-MaesterUpgradeBoolean -Name 'AUTOMATION_VALIDATE_RUNBOOK_ON_PROVISION' -Value $validationControl -Default $true | Out-Null

$schedules = @()
$runbooks = @()
if ($account) {
  if (-not $ownership.OwnedJobScheduleId) {
    throw 'An existing Automation account has no verified live association; reconcile it before provisioning.'
  }
  foreach ($kind in @('schedules', 'runbooks')) {
    $inventoryJson = & az rest --method GET --uri "https://management.azure.com$expectedAccountId/$kind`?api-version=2023-11-01" --subscription $SubscriptionId -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($inventoryJson)) { throw "Could not inspect live Automation $kind." }
    $inventory = $inventoryJson | ConvertFrom-Json -ErrorAction Stop
    Assert-MaesterCompleteInventory -Response $inventory -Name $kind
    if ($kind -eq 'schedules') { $schedules = @($inventory.value) } else { $runbooks = @($inventory.value) }
  }
}
$verifiedResources = Assert-MaesterExistingAutomationResources -ExpectedAccountId $expectedAccountId `
  -Account $account -JobSchedules $jobSchedules -Schedules $schedules -Runbooks $runbooks `
  -Ownership $ownership -RequireExisting:$preserveUpgradeAccess
if ($preserveUpgradeAccess) {
  # The bounded mode leaves non-runtime infrastructure untouched. Its existing
  # outputs must still resolve to the exact deployed resources before ARM runs.
  $getExactResource = {
    param($path)
    $json = & az rest --method GET --uri "https://management.azure.com$path" --subscription $SubscriptionId -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { throw 'Could not verify an existing deployment target for runtime-only upgrade.' }
    $json | ConvertFrom-Json -ErrorAction Stop
  }
  Resolve-MaesterDeploymentTargets -EnvironmentValues $selectedValues -SubscriptionId $SubscriptionId `
    -ResourceGroupName $rgName -EnvironmentName $EnvironmentName -SolutionName 'automation-account' -GetResource $getExactResource | Out-Null
  $verifiedAccount = Resolve-MaesterMainDeploymentTarget -EnvironmentValues $selectedValues `
    -NameOutput 'automationAccountName' -PrincipalOutput 'automationPrincipalId' `
    -ProviderType 'Microsoft.Automation/automationAccounts' -ApiVersion '2023-11-01' `
    -SubscriptionId $SubscriptionId -ResourceGroupName $rgName -EnvironmentName $EnvironmentName `
    -SolutionName 'automation-account' -GetResource $getExactResource
  if ($verifiedAccount.id -ine $expectedAccountId -or $verifiedAccount.identity.principalId -ine $account.identity.principalId) {
    throw 'The runtime-only upgrade target differs from the verified Automation ownership binding.'
  }
  if ((Get-MaesterUpgradeBoolean -Name 'INCLUDE_WEB_APP' -Value ([string]$selectedValues['INCLUDE_WEB_APP'])) -ne
      (Get-MaesterUpgradeBoolean -Name 'WEB_APP_ENABLED' -Value ([string]$selectedValues['WEB_APP_ENABLED']))) {
    throw 'Runtime-only upgrade cannot change the existing Web App deployment mode.'
  }
  # Runtime-only authorization does not authorize replacing a different script.
  # Download raw bytes to avoid CLI stdout/line-ending/JSON transformations.
  $publishedContentPath = [IO.Path]::GetTempFileName()
  try {
    & az rest --method GET --uri "https://management.azure.com$expectedAccountId/runbooks/maester-runbook/content?api-version=2024-10-23" --subscription $SubscriptionId --output-file $publishedContentPath -o none
    if ($LASTEXITCODE -ne 0 -or (Get-Item -LiteralPath $publishedContentPath).Length -eq 0) {
      throw 'Could not verify the existing published runbook content before runtime-only upgrade.'
    }
    $publishedContent = (Get-Content -LiteralPath $publishedContentPath -Raw -Encoding utf8).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
    $localContent = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-MaesterAutomationRunbook.ps1') -Raw).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
    $publishedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($publishedContent)))
    $localHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($localContent)))
    Write-Host "Published/local normalized runbook SHA-256 before upgrade: $publishedHash / $localHash"
    if ($publishedContent -cne $localContent) {
      throw 'Runtime-only upgrade requires matching published/local runbook content; review and separately authorize any script replacement before retrying.'
    }
  }
  finally { Remove-Item -LiteralPath $publishedContentPath -Force -ErrorAction SilentlyContinue }
  Write-Host 'Verified runtime-only upgrade: non-runtime infrastructure and access configuration will remain untouched.'
}

if ($ownership.OwnedJobScheduleId) {
  Write-Host "Verified existing template jobSchedule '$($ownership.OwnedJobScheduleId)'; its linkage and resource lock remain intact."
}
Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AUTOMATION_JOB_SCHEDULE_ID' -Value $ownership.JobScheduleId
Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AUTOMATION_EXISTING_RESOURCES' -Value $verifiedResources.Existing.ToString().ToLowerInvariant()
Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AUTOMATION_UPGRADE_PRESERVE_ACCESS' -Value $preserveUpgradeAccess.ToString().ToLowerInvariant()
# Runtime-only upgrades never create an Automation account or consume account quota.
if ($preserveUpgradeAccess) {
  Write-Host 'Skipping account-creation quota check for verified runtime-only upgrade.'
}
elseif ($location) {
  Write-Host "Checking Automation Account quota in region '$location'..."
  try {
    $existingAccountsJson = az automation account list --subscription $SubscriptionId --query "[?location=='$location']" -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $existingAccountsJson) {
      $existingAccounts = $existingAccountsJson | ConvertFrom-Json
      $count = @($existingAccounts).Count
      # Quota varies by subscription type: Enterprise/CSP = 10, PAYG/MSDN = 2, Free Trial = 1
      if ($count -ge 10) {
        throw "There are already $count Automation Accounts in region '$location'. This exceeds the maximum quota (10 for Enterprise, 2 for PAYG). Provision will fail. Delete unused Automation Accounts or choose a different region."
      }
      elseif ($count -ge 2) {
        Write-Warning "There are already $count Automation Accounts in region '$location'. The quota is 2 for Pay-as-you-go/MSDN subscriptions (10 for Enterprise/CSP). If your subscription type has a lower limit, provision may fail."
      }
      Write-Host "  Found $count existing Automation Account(s) in '$location'."
    }
  }
  catch [System.Management.Automation.RuntimeException] {
    throw
  }
  catch {
    Write-Warning "Could not check Automation Account quota: $_"
  }
}
else {
  Write-Warning 'AZURE_LOCATION not set. Skipping Automation Account quota check.'
}
