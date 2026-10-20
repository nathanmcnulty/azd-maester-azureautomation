#Requires -Version 7.6
[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [string]$EnvironmentName,

  [Parameter(Mandatory = $false)]
  [string]$ResourceGroupName,

  [Parameter(Mandatory = $false)]
  [string]$TenantId,

  [Parameter(Mandatory = $false)]
  [string]$SecurityGroupObjectId,

  [Parameter(Mandatory = $false)]
  [string]$SecurityGroupDisplayName,

  [Parameter(Mandatory = $false)]
  [ValidateSet('Minimal', 'Full', 'Extended')]
  [string]$PermissionProfile = 'Full',

  [Parameter(Mandatory = $false)]
  [switch]$IncludeExchange,

  [Parameter(Mandatory = $false)]
  [switch]$IncludeTeams,

  [Parameter(Mandatory = $false)]
  [switch]$IncludeAzure,

  [Parameter(Mandatory = $false)]
  [string[]]$AzureScopes,

  [switch]$IncludeMailSend,
  [switch]$IncludeReportSettingsWrite,
  [switch]$Apply,
  [string]$ApprovedPlanHash,
  [switch]$InteractiveConsent,
  [switch]$AllowInteractiveGraphLogin,
  [switch]$AllowGraphContextReplacement
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $projectRoot

Import-Module (Join-Path $PSScriptRoot 'vendor\Azd.MaesterHooks\Maester-SetupHelpers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'vendor\Azd.MaesterHooks\Maester-Helpers.psm1') -Force


# ──────────────────────────────────────────────
# Resolve parameters from environment
# ──────────────────────────────────────────────

if (-not $SubscriptionId) {
  $SubscriptionId = $env:AZURE_SUBSCRIPTION_ID
}
if (-not $SubscriptionId) {
  throw 'SubscriptionId is required. Pass -SubscriptionId or set AZURE_SUBSCRIPTION_ID.'
}

if (-not $TenantId -and $env:AZURE_TENANT_ID) {
  $TenantId = $env:AZURE_TENANT_ID
}

if ([string]::IsNullOrWhiteSpace($TenantId)) {
  throw 'TenantId is required. Pass -TenantId or set AZURE_TENANT_ID to the expected tenant.'
}

$azAccount = Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId
$TenantId = $azAccount.tenantId
$armToken = Get-AzCliAccessToken -SubscriptionId $SubscriptionId -TenantId $TenantId -Resource 'https://management.azure.com/'
if ([string]::IsNullOrWhiteSpace($armToken)) { throw 'ARM token acquisition failed for the validated target.' }
$armHeaders = @{ Authorization = "Bearer $armToken" }
if (-not $EnvironmentName) {
  $EnvironmentName = if ($env:AZURE_ENV_NAME) { $env:AZURE_ENV_NAME } else { 'dev' }
}
if (-not $PSBoundParameters.ContainsKey('PermissionProfile') -and $env:PERMISSION_PROFILE) {
  $envPermissionProfile = $env:PERMISSION_PROFILE.Trim()
  if ($envPermissionProfile -notin @('Minimal', 'Full', 'Extended')) {
    throw "PERMISSION_PROFILE must be 'Minimal', 'Full', or legacy 'Extended'. Current value: '$envPermissionProfile'."
  }
  $PermissionProfile = $envPermissionProfile
}
if (-not $SecurityGroupObjectId) {
  if ($env:SECURITY_GROUP_OBJECT_ID) {
    $SecurityGroupObjectId = $env:SECURITY_GROUP_OBJECT_ID
  }
  elseif ($env:EASY_AUTH_SECURITY_GROUP_OBJECT_ID) {
    $SecurityGroupObjectId = $env:EASY_AUTH_SECURITY_GROUP_OBJECT_ID
  }
}
if (-not $SecurityGroupDisplayName -and $env:SECURITY_GROUP_DISPLAY_NAME) {
  $SecurityGroupDisplayName = $env:SECURITY_GROUP_DISPLAY_NAME
}

# Capability selection is distinct from approval of the resulting concrete plan.
foreach ($capability in @('IncludeMailSend', 'IncludeReportSettingsWrite')) {
  $environmentKey = if ($capability -eq 'IncludeMailSend') { 'INCLUDE_MAIL_SEND' } else { 'INCLUDE_REPORT_SETTINGS_WRITE' }
  if (-not $PSBoundParameters.ContainsKey($capability)) {
    $value = [Environment]::GetEnvironmentVariable($environmentKey)
    if ($null -ne $value -and $value -notin @('true', 'false')) { throw "$environmentKey must be true or false." }
    Set-Variable -Name $capability -Value ($value -eq 'true')
  }
}

if (-not $PSBoundParameters.ContainsKey('IncludeExchange')) {
  $IncludeExchange = ConvertTo-BoolOrDefault -Value $env:INCLUDE_EXCHANGE -Default $false
}
if (-not $PSBoundParameters.ContainsKey('IncludeTeams')) {
  $IncludeTeams = ConvertTo-BoolOrDefault -Value $env:INCLUDE_TEAMS -Default $false
}
if (-not $PSBoundParameters.ContainsKey('IncludeAzure')) {
  $IncludeAzure = ConvertTo-BoolOrDefault -Value $env:INCLUDE_AZURE -Default $false
}

if (-not $PSBoundParameters.ContainsKey('AzureScopes')) {
  if ($env:AZURE_RBAC_SCOPES) {
    $rawScopes = $env:AZURE_RBAC_SCOPES.Trim()
    if ($rawScopes.StartsWith('[')) {
      try {
        $parsed = $rawScopes | ConvertFrom-Json
        if ($parsed -is [string]) {
          $AzureScopes = @($parsed)
        }
        elseif ($parsed) {
          $AzureScopes = @($parsed)
        }
      }
      catch {
        Write-Warning "AZURE_RBAC_SCOPES looked like JSON but could not be parsed. Falling back to ';' splitting. Value: $rawScopes"
        $AzureScopes = @($rawScopes -split ';' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      }
    }
    else {
      $AzureScopes = @($rawScopes -split ';' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
  }
}

if ($IncludeAzure -and (-not $AzureScopes -or $AzureScopes.Count -eq 0)) {
  $AzureScopes = @("/subscriptions/$SubscriptionId")
}

$securityGroupSource = 'parameter'
if (-not $PSBoundParameters.ContainsKey('SecurityGroupObjectId') -and -not $PSBoundParameters.ContainsKey('SecurityGroupDisplayName')) {
  if ($env:SECURITY_GROUP_OBJECT_ID -or $env:EASY_AUTH_SECURITY_GROUP_OBJECT_ID) {
    $securityGroupSource = 'environment'
  }
}

$resolvedResourceGroupName = if ($ResourceGroupName) { $ResourceGroupName } elseif ($env:AZURE_RESOURCE_GROUP) { $env:AZURE_RESOURCE_GROUP } else { "rg-$EnvironmentName" }

. (Join-Path $PSScriptRoot 'Resolve-DeploymentTargets.ps1')
. (Join-Path $PSScriptRoot 'JobScheduleOwnership.ps1')
$deploymentValues = Get-MaesterDeploymentValues -EnvironmentName $EnvironmentName -SubscriptionId $SubscriptionId -ResourceGroupName $resolvedResourceGroupName
$targets = Resolve-MaesterDeploymentTargets -EnvironmentValues $deploymentValues -SubscriptionId $SubscriptionId -ResourceGroupName $resolvedResourceGroupName -EnvironmentName $EnvironmentName -SolutionName 'automation-account' -GetResource {
  param($path)
  Invoke-RestMethod -Method GET -Uri "https://management.azure.com$path" -Headers $armHeaders
}
$storageAccount = $targets.StorageAccount
$webApp = $targets.WebApp
$automationAccount = Resolve-MaesterMainDeploymentTarget -EnvironmentValues $deploymentValues `
  -NameOutput 'automationAccountName' -PrincipalOutput 'automationPrincipalId' `
  -ProviderType 'Microsoft.Automation/automationAccounts' -ApiVersion '2023-11-01' `
  -SubscriptionId $SubscriptionId -ResourceGroupName $resolvedResourceGroupName `
  -EnvironmentName $EnvironmentName -SolutionName 'automation-account' -GetResource {
    param($path)
    Invoke-RestMethod -Method GET -Uri "https://management.azure.com$path" -Headers $armHeaders
  }
$automationAccountName = [string]$automationAccount.name
$expectedAutomationAccountId = [string]$automationAccount.id
$principalId = [string]$automationAccount.identity.principalId

# Strict, local upgrade controls are separate from the shared setup wizard.
if ($null -ne $env:AUTOMATION_UPGRADE_PRESERVE_ACCESS -and
    $deploymentValues.ContainsKey('AUTOMATION_UPGRADE_PRESERVE_ACCESS') -and
    $env:AUTOMATION_UPGRADE_PRESERVE_ACCESS -ine [string]$deploymentValues['AUTOMATION_UPGRADE_PRESERVE_ACCESS']) {
  throw 'The process AUTOMATION_UPGRADE_PRESERVE_ACCESS differs from the selected azd environment.'
}
$preserveAccessValue = if ($deploymentValues.ContainsKey('AUTOMATION_UPGRADE_PRESERVE_ACCESS')) {
  [string]$deploymentValues['AUTOMATION_UPGRADE_PRESERVE_ACCESS']
} elseif ($null -ne $env:AUTOMATION_UPGRADE_PRESERVE_ACCESS) {
  $env:AUTOMATION_UPGRADE_PRESERVE_ACCESS
} else { 'false' }
if ($preserveAccessValue -notin @('true', 'false')) {
  throw 'AUTOMATION_UPGRADE_PRESERVE_ACCESS must be true or false.'
}
$preserveExistingAccess = $preserveAccessValue -eq 'true'
if ($null -ne $env:AUTOMATION_EXISTING_RESOURCES -and
    $deploymentValues.ContainsKey('AUTOMATION_EXISTING_RESOURCES') -and
    $env:AUTOMATION_EXISTING_RESOURCES -ine [string]$deploymentValues['AUTOMATION_EXISTING_RESOURCES']) {
  throw 'The process AUTOMATION_EXISTING_RESOURCES differs from the selected azd environment.'
}
$existingResourcesValue = if ($deploymentValues.ContainsKey('AUTOMATION_EXISTING_RESOURCES')) {
  [string]$deploymentValues['AUTOMATION_EXISTING_RESOURCES']
} elseif ($null -ne $env:AUTOMATION_EXISTING_RESOURCES) {
  $env:AUTOMATION_EXISTING_RESOURCES
} else { $null }
if ($null -ne $existingResourcesValue -and $existingResourcesValue -notin @('true', 'false')) {
  throw 'AUTOMATION_EXISTING_RESOURCES must be true or false.'
}

$jobScheduleId = [string]$deploymentValues['AUTOMATION_JOB_SCHEDULE_ID']
if (-not (Test-MaesterGuid -Value $jobScheduleId)) {
  throw 'AUTOMATION_JOB_SCHEDULE_ID must be a GUID before changing the Automation deployment.'
}
$ownershipParameters = @{
  ReceiptAccountId = [string]$deploymentValues['AUTOMATION_OWNED_ACCOUNT_ID']
  ReceiptPrincipalId = [string]$deploymentValues['AUTOMATION_OWNED_PRINCIPAL_ID']
  ReceiptJobScheduleId = [string]$deploymentValues['AUTOMATION_OWNED_JOB_SCHEDULE_ID']
  AdoptAccountId = [string]$deploymentValues['AUTOMATION_ADOPT_ACCOUNT_ID']
  AdoptPrincipalId = [string]$deploymentValues['AUTOMATION_ADOPT_PRINCIPAL_ID']
  AdoptJobScheduleId = [string]$deploymentValues['AUTOMATION_ADOPT_JOB_SCHEDULE_ID']
}

function Get-MaesterPostDeployAutomationState {
  # Never interpret an unreadable, malformed, or truncated inventory as absence.
  $account = Resolve-MaesterMainDeploymentTarget -EnvironmentValues $deploymentValues `
    -NameOutput 'automationAccountName' -PrincipalOutput 'automationPrincipalId' `
    -ProviderType 'Microsoft.Automation/automationAccounts' -ApiVersion '2023-11-01' `
    -SubscriptionId $SubscriptionId -ResourceGroupName $resolvedResourceGroupName `
    -EnvironmentName $EnvironmentName -SolutionName 'automation-account' -GetResource {
      param($path)
      Invoke-RestMethod -Method GET -Uri "https://management.azure.com$path" -Headers $armHeaders
    }
  $inventories = @{}
  foreach ($childType in @('jobSchedules', 'schedules', 'runbooks')) {
    $response = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$expectedAutomationAccountId/$childType`?api-version=2023-11-01" -Headers $armHeaders
    Assert-MaesterCompleteInventory -Response $response -Name $childType
    $inventories[$childType] = @($response.value)
  }
  Assert-MaesterJobScheduleWriteTarget -ExpectedAccountId $expectedAutomationAccountId -ExpectedPrincipalId $principalId `
    -JobScheduleId $jobScheduleId -Account $account -JobSchedules $inventories['jobSchedules'] @ownershipParameters
  $ownership = [pscustomobject]@{ JobScheduleId = $jobScheduleId; OwnedJobScheduleId = '' }
  if (@($inventories['jobSchedules'] | Where-Object {
      [string]$_.properties.schedule.name -ieq 'maester-weekly-sunday' -and
      [string]$_.properties.runbook.name -ieq 'maester-runbook'
    }).Count -gt 0) {
    $ownership = Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $expectedAutomationAccountId `
      -Account $account -JobSchedules $inventories['jobSchedules'] @ownershipParameters
  }
  $resources = Assert-MaesterExistingAutomationResources -ExpectedAccountId $expectedAutomationAccountId `
    -Account $account -JobSchedules $inventories['jobSchedules'] -Schedules $inventories['schedules'] `
    -Runbooks $inventories['runbooks'] -Ownership $ownership -RequireExisting:$preserveExistingAccess
  return [pscustomobject]@{ Account = $account; Resources = $resources }
}

function Assert-CurrentSetupTargets {
  $null = Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId
  $current = Resolve-MaesterDeploymentTargets -EnvironmentValues $deploymentValues -SubscriptionId $SubscriptionId -ResourceGroupName $resolvedResourceGroupName -EnvironmentName $EnvironmentName -SolutionName 'automation-account' -GetResource {
    param($path)
    Invoke-RestMethod -Method GET -Uri "https://management.azure.com$path" -Headers $armHeaders
  }
  $currentRuntime = Resolve-MaesterMainDeploymentTarget -EnvironmentValues $deploymentValues `
    -NameOutput 'automationAccountName' -PrincipalOutput 'automationPrincipalId' `
    -ProviderType 'Microsoft.Automation/automationAccounts' -ApiVersion '2023-11-01' `
    -SubscriptionId $SubscriptionId -ResourceGroupName $resolvedResourceGroupName `
    -EnvironmentName $EnvironmentName -SolutionName 'automation-account' -GetResource {
      param($path)
      Invoke-RestMethod -Method GET -Uri "https://management.azure.com$path" -Headers $armHeaders
    }
  if ($currentRuntime.id -ine $automationAccount.id -or $currentRuntime.identity.principalId -ine $principalId -or
      $current.StorageAccount.id -ine $storageAccount.id -or
      (($null -eq $current.WebApp) -ne ($null -eq $webApp)) -or
      ($webApp -and $current.WebApp.id -ine $webApp.id)) { throw 'Deployment targets changed after setup planning.' }
}

# Complete all exact-target, ownership, and live-child checks before any write.
$initialAutomationState = Get-MaesterPostDeployAutomationState
$existingAutomationResources = [bool]$initialAutomationState.Resources.Existing
$originalAssociationProperties = if ($existingAutomationResources) {
  ConvertTo-MaesterJobSchedulePropertiesJson $initialAutomationState.Resources.JobSchedule.properties
} else { $null }
$originalScheduleProperties = if ($existingAutomationResources) {
  ConvertTo-MaesterCanonicalJson $initialAutomationState.Resources.Schedule.properties
} else { $null }
if ($null -ne $existingResourcesValue -and
    (($existingResourcesValue -eq 'true') -ne $existingAutomationResources)) {
  throw 'The live Automation resources differ from the verified preprovision state.'
}
$ownershipSession = $null
try {
  if ($preserveExistingAccess) {
    $ownershipPath = Join-Path $projectRoot ".azure/$EnvironmentName/maester-setup-ownership.json"
    if (Test-Path -LiteralPath $ownershipPath) {
      Import-Module (Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Maester-InfrastructureOwnership.psm1')
      Register-MaesterExternalSetupStarted -ProjectRoot $projectRoot -EnvironmentName $EnvironmentName -SolutionName 'automation-account' -TenantId $TenantId -SubscriptionId $SubscriptionId -ResourceGroupName $resolvedResourceGroupName | Out-Null
      Import-Module (Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Maester-OwnershipJournal.psm1')
      $ownershipBinding = @{
        environmentName = $EnvironmentName; tenantId = $TenantId.ToLowerInvariant(); subscriptionId = $SubscriptionId.ToLowerInvariant()
        solutionName = 'automation-account'; resourceGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$resolvedResourceGroupName"
        setupClientId = $env:MAESTER_SETUP_CLIENT_ID.ToLowerInvariant()
        runtimeResourceId = [string]$automationAccount.id; runtimePrincipalId = $principalId.ToLowerInvariant()
      }
      $ownershipSession = Open-MaesterOwnershipJournal -ProjectRoot $projectRoot -Binding $ownershipBinding -RequireExisting
      Assert-CurrentSetupTargets
      $null = Get-MaesterPostDeployAutomationState
    }
    Write-Host 'Verified existing Automation deployment; preserving all permissions, setup receipts, and Easy Auth settings.'
  }
  else {
    # Access planning runs only after every deployment target and ownership guard.
    Import-Module (Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Maester-ConsentPlan.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Maester-SetupConsent.psm1') -Force
    $includeWebApp = $null -ne $webApp
    if ($AllowGraphContextReplacement -and -not $AllowInteractiveGraphLogin) {
      throw 'Context replacement requires explicit -AllowInteractiveGraphLogin and -AllowGraphContextReplacement.'
    }
    if ($InteractiveConsent -and -not $AllowInteractiveGraphLogin) {
      if ($env:CI -eq 'true' -or $env:AZD_NON_INTERACTIVE -eq 'true' -or [Console]::IsInputRedirected) {
        throw 'Interactive setup is unavailable. Generate a plan with an existing session, then pass -Apply -ApprovedPlanHash.'
      }
      $answer = Read-Host "Allow normal browser sign-in if needed for setup account '$env:MAESTER_SETUP_ACCOUNT' and tenant '$TenantId'? [y/N]"
      $AllowInteractiveGraphLogin = $answer -match '^(?i:y|yes)$'
    }
    Assert-GraphAccess -TenantId $TenantId -ClientId $env:MAESTER_SETUP_CLIENT_ID -ExpectedAccount $env:MAESTER_SETUP_ACCOUNT `
      -Scopes (Get-MaesterSetupScopes -IncludeTeams:$IncludeTeams -IncludeWebApp:$includeWebApp) `
      -AllowInteractive:$AllowInteractiveGraphLogin -AllowContextReplacement:$AllowGraphContextReplacement

    if ($IncludeExchange) {
      # Reading Exchange RBAC is mandatory before approval. No best-effort fallback
      # can convert a missing module or failed inventory into a grant.
      if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        throw 'Install the reviewed ExchangeOnlineManagement module before planning Exchange access.'
      }
      $organization = Invoke-GraphRestRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=verifiedDomains'
      $domains = @($organization.value | ForEach-Object { $_.verifiedDomains } | Where-Object { $_.isInitial -eq $true })
      if ($domains.Count -ne 1) { throw 'Exactly one initial tenant domain is required to inspect Exchange access.' }
      Connect-ExchangeOnlineSilent -Organization $domains[0].name -TenantId $TenantId
    }
    $accessPlanParameters = @{
      TenantId = $TenantId; SubscriptionId = $SubscriptionId; PrincipalObjectId = $principalId
      ResourceId = $expectedAutomationAccountId; StorageAccount = $storageAccount; WebApp = $webApp; ArmHeaders = $armHeaders
      SecurityGroupObjectId = $SecurityGroupObjectId; SecurityGroupDisplayName = $SecurityGroupDisplayName
      PermissionProfile = $PermissionProfile; IncludeMailSend = [bool]$IncludeMailSend
      IncludeReportSettingsWrite = [bool]$IncludeReportSettingsWrite
      IncludeExchange = $IncludeExchange; IncludeTeams = $IncludeTeams; IncludeAzure = $IncludeAzure; AzureScopes = $AzureScopes
    }
    $accessPlan = Get-MaesterSetupAccessPlan @accessPlanParameters
    Write-Host ($accessPlan | ConvertTo-Json -Depth 30)
    if ($InteractiveConsent) {
      $ApprovedPlanHash = Confirm-MaesterConsentPlan -Plan $accessPlan
      $Apply = $true
    }
    if (-not $Apply) {
      Write-Host 'Plan only. No setup grants, application changes, uploads, or receipts were written. Review the plan and rerun with -Apply -ApprovedPlanHash.'
      return $accessPlan
    }
    Assert-MaesterConsentPlanApproval -Plan $accessPlan -ApprovedPlanHash $ApprovedPlanHash
    Import-Module (Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Maester-InfrastructureOwnership.psm1')
    Register-MaesterExternalSetupStarted -ProjectRoot $projectRoot -EnvironmentName $EnvironmentName -SolutionName 'automation-account' -TenantId $TenantId -SubscriptionId $SubscriptionId -ResourceGroupName $resolvedResourceGroupName | Out-Null
    Import-Module (Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Maester-OwnershipJournal.psm1')
    $ownershipBinding = @{
      environmentName = $EnvironmentName; tenantId = $TenantId.ToLowerInvariant(); subscriptionId = $SubscriptionId.ToLowerInvariant()
      solutionName = 'automation-account'; resourceGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$resolvedResourceGroupName"
      setupClientId = $env:MAESTER_SETUP_CLIENT_ID.ToLowerInvariant()
      runtimeResourceId = [string]$automationAccount.id; runtimePrincipalId = $principalId.ToLowerInvariant()
    }
    $ownershipSession = Open-MaesterOwnershipJournal -ProjectRoot $projectRoot -Binding $ownershipBinding
    Assert-CurrentSetupTargets
    $null = Get-MaesterPostDeployAutomationState
    $accessResult = Invoke-MaesterSetupAccessPlan -PlanParameters $accessPlanParameters -ApprovedPlanHash $ApprovedPlanHash -OwnershipSession $ownershipSession
    Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AUTOMATION_MI_PRINCIPAL_ID' -Value $principalId

    $exchangeSetupStatus = if ($IncludeExchange) { 'configured' } else { 'disabled' }
    $teamsSetupStatus = if ($IncludeTeams) { 'configured' } else { 'disabled' }
    $azureSetupStatus = if ($IncludeAzure) { 'configured' } else { 'disabled' }
    Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'SETUP_EXCHANGE_STATUS' -Value $exchangeSetupStatus
    Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'SETUP_TEAMS_STATUS' -Value $teamsSetupStatus
    Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'SETUP_AZURE_STATUS' -Value $azureSetupStatus
    foreach ($receiptName in @('EXO_APPROLE_ASSIGNMENT_IDS', 'TEAMS_READER_ROLE_ASSIGNMENT_IDS', 'AZURE_ROLE_ASSIGNMENT_IDS')) {
      $priorReceipt = [string]$deploymentValues[$receiptName]
      $priorIds = if ($priorReceipt.Trim().StartsWith('[')) { @($priorReceipt | ConvertFrom-Json -ErrorAction Stop) } else { @($priorReceipt -split ';' | Where-Object { $_ }) }
      # Legacy IDs are retained for operator recovery only; the journal is authoritative.
      Set-MaesterAzdEnvJsonArray -EnvironmentName $EnvironmentName -Name $receiptName -Values @($priorIds + @($accessResult.Receipts[$receiptName]))
    }
    if ($IncludeExchange) {
      Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'EXO_SERVICE_PRINCIPAL_DISPLAY_NAME' -Value $accessResult.PrincipalDisplayName
    }
    if ($accessResult.EasyAuth) {
      Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'EASY_AUTH_ENTRA_APP_OBJECT_ID' -Value $accessResult.EasyAuth.objectId
      Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'EASY_AUTH_ENTRA_APP_CLIENT_ID' -Value $accessResult.EasyAuth.clientId
      Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'EASY_AUTH_ENTRA_APP_DISPLAY_NAME' -Value $accessResult.EasyAuth.displayName
      $SecurityGroupObjectId = $accessResult.EasyAuth.securityGroupId
    }

  }

  # ──────────────────────────────────────────────
  # Publish runbook to Automation Account
  # ──────────────────────────────────────────────

  $runbookContentPath = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-MaesterAutomationRunbook.ps1'
  if (-not (Test-Path -Path $runbookContentPath)) {
    throw "Runbook content file was not found: $runbookContentPath"
  }

  $runbookName = 'maester-runbook'
  $runbookContent = Get-Content -Path $runbookContentPath -Raw
  $armApiVersion = '2024-10-23'

  $expectedRunbookContent = $runbookContent.TrimStart([char]0xFEFF).Replace("`r`n", "`n")
  $contentUri = "/subscriptions/$SubscriptionId/resourceGroups/$resolvedResourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName/runbooks/$runbookName/content?api-version=$armApiVersion"
  $publishLocalContent = $true
  if ($existingAutomationResources) {
    $originalContent = [string](Invoke-RestMethod -Method GET -Uri "https://management.azure.com$contentUri" -Headers $armHeaders)
    $normalizedOriginalContent = $originalContent.TrimStart([char]0xFEFF).Replace("`r`n", "`n")
    $originalHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($normalizedOriginalContent)))
    $localHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($expectedRunbookContent)))
    Write-Host "Published/local normalized runbook SHA-256: $originalHash / $localHash"
    $publishLocalContent = $normalizedOriginalContent -cne $expectedRunbookContent
    if ($preserveExistingAccess -and $publishLocalContent) {
      throw "Runtime-only preservation requires matching published/local runbook content. SHA-256 mismatch: published $originalHash; local $localHash. Reconcile the runbook before upgrading."
    }
  }
  if ($publishLocalContent) {
    $draftUri = "/subscriptions/$SubscriptionId/resourceGroups/$resolvedResourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName/runbooks/$runbookName/draft/content?api-version=$armApiVersion"
    Invoke-RestMethod -Method PUT -Uri "https://management.azure.com$draftUri" -Headers $armHeaders -Body $runbookContent -ContentType 'text/powershell' | Out-Null
    Write-Host "Uploaded draft content for runbook '$runbookName'."

    $publishUri = "/subscriptions/$SubscriptionId/resourceGroups/$resolvedResourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName/runbooks/$runbookName/publish?api-version=$armApiVersion"
    Invoke-RestMethod -Method POST -Uri "https://management.azure.com$publishUri" -Headers $armHeaders -Body '{}' -ContentType 'application/json' | Out-Null
    Write-Host "Published runbook '$runbookName' with local script content."
  }
  else {
    Write-Host "Published runbook '$runbookName' already matches the local script; publication was skipped."
  }

  # The infrastructure creates the weekly schedule without an association. Attach it
  # only after the locally maintained runbook has replaced the pinned seed content.
  $expectedRunbookContent = $runbookContent.TrimStart([char]0xFEFF).Replace("`r`n", "`n")
  $publishedLocalRunbook = $false
  $runbookResourceUri = "/subscriptions/$SubscriptionId/resourceGroups/$resolvedResourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName/runbooks/$runbookName`?api-version=$armApiVersion"
  $contentUri = "/subscriptions/$SubscriptionId/resourceGroups/$resolvedResourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName/runbooks/$runbookName/content?api-version=$armApiVersion"
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    $runbookResource = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$runbookResourceUri" -Headers $armHeaders
    if ($runbookResource.properties.state -eq 'Published') {
      $publishedContent = [string](Invoke-RestMethod -Method GET -Uri "https://management.azure.com$contentUri" -Headers $armHeaders)
      if ($publishedContent.TrimStart([char]0xFEFF).Replace("`r`n", "`n") -ceq $expectedRunbookContent) {
        $publishedLocalRunbook = $true
        break
      }
    }
    Start-Sleep -Seconds 2
  }
  if (-not $publishedLocalRunbook) { throw 'Local Maester runbook publication was not confirmed; weekly schedule was not attached.' }

  # Existing runbooks are deliberately absent from ARM: a PUT can create an Edit
  # draft even without content. Rebind only through the documented direct PATCH,
  # after fresh exact ownership/linkage and published/local content verification.
  if ($existingAutomationResources) {
    $beforeRuntimeState = Get-MaesterPostDeployAutomationState
    if (-not $beforeRuntimeState.Resources.Existing -or
        (ConvertTo-MaesterJobSchedulePropertiesJson $beforeRuntimeState.Resources.JobSchedule.properties) -cne $originalAssociationProperties -or
        (ConvertTo-MaesterCanonicalJson $beforeRuntimeState.Resources.Schedule.properties) -cne $originalScheduleProperties) {
      throw 'The existing Automation association or schedule changed before the runtime PATCH.'
    }
    Update-MaesterExistingRunbookRuntime -ExpectedAccountId $expectedAutomationAccountId `
      -ExpectedRuntimeName $deploymentValues['automationRuntimeEnvironmentName'] `
      -ExpectedRuntimeVersion $deploymentValues['automationRuntimeEnvironmentVersion'] `
      -ExpectedContent $runbookContent -GetResource {
        param($path)
        Invoke-RestMethod -Method GET -Uri "https://management.azure.com$path" -Headers $armHeaders
      } -GetContent {
        param($path)
        Invoke-RestMethod -Method GET -Uri "https://management.azure.com$path" -Headers $armHeaders
      } -PatchResource {
        param($path, $body)
        Invoke-RestMethod -Method PATCH -Uri "https://management.azure.com$path" -Headers $armHeaders -Body $body -ContentType 'application/json'
      } | Out-Null
  }

  # Re-read all children after publication, before touching any association. Existing
  # associations are read back only, retaining custom parameters, runOn, and IDs.
  $finalAutomationState = Get-MaesterPostDeployAutomationState
  if ([bool]$finalAutomationState.Resources.Existing -ne $existingAutomationResources) {
    throw 'The Automation association changed during postdeployment; refusing to recreate or overwrite it.'
  }
  if ($existingAutomationResources) {
    # The legacy inventory API verifies ownership/state but omits runtimeEnvironment.
    # Read the exact target again through the runtime-capable API; never infer it.
    $finalRunbook = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$runbookResourceUri" -Headers $armHeaders
    $finalRunbookRecord = $finalRunbook | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    Get-MaesterRunbookPreservationMetadata -ExpectedAccountId $expectedAutomationAccountId -Runbook $finalRunbookRecord | Out-Null
    $finalRuntime = $finalRunbookRecord['properties']['runtimeEnvironment']
    if ($finalRuntime -isnot [string] -or $finalRuntime -ine $deploymentValues['automationRuntimeEnvironmentName']) {
      throw 'The existing runbook runtime binding changed during final postdeployment readback.'
    }
  }
  if ($existingAutomationResources -and
      (ConvertTo-MaesterCanonicalJson $finalAutomationState.Resources.Schedule.properties) -cne $originalScheduleProperties) {
    throw 'The existing Automation schedule properties changed during postdeployment.'
  }
  if ($existingAutomationResources -and
      (ConvertTo-MaesterJobSchedulePropertiesJson $finalAutomationState.Resources.JobSchedule.properties) -cne $originalAssociationProperties) {
    throw 'The existing Automation association properties changed during final inventory readback.'
  }
  $liveAccount = $finalAutomationState.Account
  $jobScheduleUri = "/subscriptions/$SubscriptionId/resourceGroups/$resolvedResourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName/jobSchedules/$jobScheduleId`?api-version=2023-11-01"
  if (-not $existingAutomationResources) {
    $jobScheduleBody = @{ properties = @{ schedule = @{ name = 'maester-weekly-sunday' }; runbook = @{ name = $runbookName } } } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Method PUT -Uri "https://management.azure.com$jobScheduleUri" -Headers $armHeaders -Body $jobScheduleBody -ContentType 'application/json' | Out-Null
  }
  $verifiedSchedule = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$jobScheduleUri" -Headers $armHeaders
  Assert-MaesterJobScheduleIdentity -ExpectedAccountId $expectedAutomationAccountId -ExpectedJobScheduleId $jobScheduleId -JobSchedule $verifiedSchedule
  Assert-MaesterOwnershipReceiptTarget -ExpectedAccountId $expectedAutomationAccountId -ExpectedPrincipalId $principalId `
    -ExpectedJobScheduleId $jobScheduleId -Account $liveAccount -JobSchedule $verifiedSchedule
  if ($existingAutomationResources -and
      (ConvertTo-MaesterJobSchedulePropertiesJson $verifiedSchedule.properties) -cne $originalAssociationProperties) {
    throw 'The existing Automation association properties changed during postdeployment.'
  }
  # Preserve existing receipts exactly; explicit adoption records a receipt only
  # after the live association has been verified without rewriting it.
  if (-not $preserveExistingAccess -or [string]::IsNullOrWhiteSpace($ownershipParameters.ReceiptAccountId)) {
    Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AUTOMATION_OWNED_ACCOUNT_ID' -Value $expectedAutomationAccountId
    Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AUTOMATION_OWNED_PRINCIPAL_ID' -Value $principalId
    Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AUTOMATION_OWNED_JOB_SCHEDULE_ID' -Value $jobScheduleId
  }
  if ($existingAutomationResources) {
    Write-Host "Verified existing weekly association for local runbook '$runbookName'; its properties were retained."
  }
  else {
    # The successful first association is now an existing deployment, including
    # when a caller retries this script directly after a later summary failure.
    Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'AUTOMATION_EXISTING_RESOURCES' -Value 'true'
    $env:AUTOMATION_EXISTING_RESOURCES = 'true'
    Write-Host "Attached verified local runbook '$runbookName' to the weekly schedule."
  }

} finally {
  if ($null -ne $ownershipSession) { $ownershipSession.Dispose() }
}
