. (Join-Path $PSScriptRoot 'PreservationMetadata.ps1')
. (Join-Path $PSScriptRoot 'JobScheduleOwnership.ps1')
. (Join-Path $PSScriptRoot 'Resolve-AutomationStorageTarget.ps1')

function Assert-MaesterAzdEnvironmentContext {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$EnvironmentName)

  if ($env:AZURE_ENV_NAME -and $env:AZURE_ENV_NAME -ine $EnvironmentName) {
    throw 'The process Azure environment differs from the requested azd environment.'
  }
  $defaultValues = & azd env get-values --output json | ConvertFrom-Json -AsHashtable
  if ($LASTEXITCODE -ne 0 -or -not $defaultValues -or $defaultValues['AZURE_ENV_NAME'] -ine $EnvironmentName) {
    throw 'The default azd environment differs from the requested environment.'
  }
  return $defaultValues
}

function Get-MaesterDeploymentValues {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$EnvironmentName, [Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$ResourceGroupName)

  Assert-MaesterAzdEnvironmentContext -EnvironmentName $EnvironmentName | Out-Null
  $values = & azd env get-values -e $EnvironmentName --output json | ConvertFrom-Json -AsHashtable
  if ($LASTEXITCODE -ne 0 -or -not $values -or $values['AZURE_ENV_NAME'] -ine $EnvironmentName -or
      $values['AZURE_SUBSCRIPTION_ID'] -ine $SubscriptionId -or
      ($values['AZURE_RESOURCE_GROUP'] -and $values['AZURE_RESOURCE_GROUP'] -ine $ResourceGroupName)) {
    throw 'The requested azd environment and selected Azure subscription/resource group could not be verified.'
  }
  return $values
}

function Set-MaesterAzdEnvValue {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$EnvironmentName, [Parameter(Mandatory)][string]$Name, [AllowEmptyString()][string]$Value)

  & azd env set -e $EnvironmentName $Name $Value | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to persist $Name to azd environment '$EnvironmentName'." }
}

function Set-MaesterAzdEnvJsonArray {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$EnvironmentName, [Parameter(Mandatory)][string]$Name, [AllowEmptyCollection()][string[]]$Values = @())

  $serialized = (@($Values) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique) -join ';'
  Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name $Name -Value $serialized
}

function Resolve-MaesterDeploymentTargets {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentValues,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$SolutionName,
    [Parameter(Mandatory)][scriptblock]$GetResource
  )

  $explicitSolutionTag = Resolve-MaesterUpgradeControlValue -EnvironmentValues $EnvironmentValues -Name 'AUTOMATION_ADOPT_SOLUTION_TAG'
  $expectedSolutionTag = if (-not [string]::IsNullOrEmpty($explicitSolutionTag)) {
    Resolve-MaesterPreservationSolutionTag -EnvironmentValues $EnvironmentValues -SubscriptionId $SubscriptionId `
      -ResourceGroupName $ResourceGroupName -EnvironmentName $EnvironmentName
  } else { $SolutionName }
  $solutionTagComparer = if (-not [string]::IsNullOrEmpty($explicitSolutionTag)) { [StringComparer]::Ordinal } else { [StringComparer]::OrdinalIgnoreCase }
  $storageName = [string]$EnvironmentValues['STORAGE_ACCOUNT_NAME']
  if ($storageName -cnotmatch '^[a-z0-9]{3,24}$') {
    throw 'Deployment output STORAGE_ACCOUNT_NAME is missing or invalid.'
  }
  $includeWebApp = [string]$EnvironmentValues['WEB_APP_ENABLED']
  if ($includeWebApp -notin @('true', 'false')) {
    throw 'Deployment output WEB_APP_ENABLED must be true or false.'
  }

  $scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
  if ((Resolve-MaesterUpgradeControlValue -EnvironmentValues $EnvironmentValues -Name 'AUTOMATION_UPGRADE_PRESERVE_ACCESS') -ieq 'true') {
    # ARM's resourceGroup().id is authoritative, including its stored casing.
    $group = & $GetResource "${scope}?api-version=2021-04-01"
    if (-not $group -or [string]$group.id -ine $scope -or [string]$group.name -ine $ResourceGroupName -or
        [string]$group.type -ine 'Microsoft.Resources/resourceGroups') {
      throw 'The runtime-only upgrade resource group does not match its exact subscription and name.'
    }
    Assert-MaesterDeterministicStorageTarget -EnvironmentValues $EnvironmentValues -SubscriptionId $SubscriptionId `
      -ResourceGroupName $ResourceGroupName -EnvironmentName $EnvironmentName -ResourceGroupId ([string]$group.id)
  }
  $storageId = "$scope/providers/Microsoft.Storage/storageAccounts/$storageName"
  $storage = & $GetResource "${storageId}?api-version=2023-05-01"
  if (-not $storage -or $storage.id -ine $storageId -or $storage.name -ine $storageName -or $storage.type -ine 'Microsoft.Storage/storageAccounts' -or
      -not $storage.tags -or $storage.tags.workload -ine 'maester' -or -not $solutionTagComparer.Equals([string]$storage.tags.solution, $expectedSolutionTag) -or
      $storage.tags.environment -ine $EnvironmentName -or $storage.tags.managedBy -ine 'azd') {
    throw "The deployed storage account '$storageName' was not found at its exact subscription and resource-group scope."
  }

  $webApp = $null
  if ($includeWebApp -eq 'true') {
    $webAppName = [string]$EnvironmentValues['WEB_APP_NAME']
    if ($webAppName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,58}[a-zA-Z0-9]$') {
      throw 'Deployment output WEB_APP_NAME is missing or invalid for WEB_APP_ENABLED=true.'
    }
    $webAppId = "$scope/providers/Microsoft.Web/sites/$webAppName"
    $webApp = & $GetResource "${webAppId}?api-version=2023-12-01"
    if (-not $webApp -or $webApp.id -ine $webAppId -or $webApp.name -ine $webAppName -or $webApp.type -ine 'Microsoft.Web/sites' -or
        -not $webApp.tags -or $webApp.tags.workload -ine 'maester' -or -not $solutionTagComparer.Equals([string]$webApp.tags.solution, $expectedSolutionTag) -or
        $webApp.tags.environment -ine $EnvironmentName -or $webApp.tags.managedBy -ine 'azd' -or $webApp.kind -like '*functionapp*') {
      throw "The deployed Web App '$webAppName' was not found at its exact subscription and resource-group scope."
    }
    if ([string]::IsNullOrWhiteSpace([string]$webApp.properties.defaultHostName)) {
      throw "The deployed Web App '$webAppName' has no default host name."
    }
  }

  return [pscustomobject]@{ StorageAccount = $storage; WebApp = $webApp }
}

function Resolve-MaesterMainDeploymentTarget {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentValues,
    [Parameter(Mandatory)][string]$NameOutput,
    [Parameter(Mandatory)][string]$PrincipalOutput,
    [Parameter(Mandatory)][string]$ProviderType,
    [Parameter(Mandatory)][string]$ApiVersion,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$SolutionName,
    [ValidateSet('Any', 'FunctionApp')][string]$Kind = 'Any',
    [Parameter(Mandatory)][scriptblock]$GetResource
  )

  $explicitSolutionTag = Resolve-MaesterUpgradeControlValue -EnvironmentValues $EnvironmentValues -Name 'AUTOMATION_ADOPT_SOLUTION_TAG'
  $expectedSolutionTag = if (-not [string]::IsNullOrEmpty($explicitSolutionTag)) {
    Resolve-MaesterPreservationSolutionTag -EnvironmentValues $EnvironmentValues -SubscriptionId $SubscriptionId `
      -ResourceGroupName $ResourceGroupName -EnvironmentName $EnvironmentName
  } else { $SolutionName }
  $solutionTagComparer = if (-not [string]::IsNullOrEmpty($explicitSolutionTag)) { [StringComparer]::Ordinal } else { [StringComparer]::OrdinalIgnoreCase }

  $name = [string]$EnvironmentValues[$NameOutput]
  $principal = [string]$EnvironmentValues[$PrincipalOutput]
  $parsedPrincipal = [guid]::Empty
  if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,78}[A-Za-z0-9]$' -or
      -not [guid]::TryParse($principal, [ref]$parsedPrincipal)) {
    throw "Deployment outputs $NameOutput and $PrincipalOutput must identify the main runtime resource."
  }
  $id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/$ProviderType/$name"
  $resource = & $GetResource "${id}?api-version=$ApiVersion"
  if (-not $resource -or $resource.id -ine $id -or $resource.name -ine $name -or
      $resource.type -ine $ProviderType -or -not $resource.tags -or
      $resource.tags.workload -ine 'maester' -or -not $solutionTagComparer.Equals([string]$resource.tags.solution, $expectedSolutionTag) -or
      $resource.tags.environment -ine $EnvironmentName -or $resource.tags.managedBy -ine 'azd' -or
      [string]$resource.identity.principalId -ine $principal -or
      [string]$resource.identity.type -notmatch '(^|,\s*)SystemAssigned($|\s*,)') {
    throw "The deployed $ProviderType resource '$name' does not match its exact output, scope, tags, and managed identity."
  }
  if (-not [string]::IsNullOrEmpty($explicitSolutionTag)) {
    if ($ProviderType -ine 'Microsoft.Automation/automationAccounts') {
      throw 'Explicit custom solution metadata preservation requires the Automation account target.'
    }
    # A custom tag is metadata, never proof of ownership. Re-read the actual
    # association here so every stage binds it to the selected receipt/adoption.
    $inventory = & $GetResource "${id}/jobSchedules?api-version=2023-11-01"
    Assert-MaesterCompleteInventory -Response $inventory -Name 'jobSchedules'
    $ownership = Resolve-MaesterJobScheduleOwnership -ExpectedAccountId $id -Account $resource -JobSchedules @($inventory.value) `
      -ReceiptAccountId ([string]$EnvironmentValues['AUTOMATION_OWNED_ACCOUNT_ID']) `
      -ReceiptPrincipalId ([string]$EnvironmentValues['AUTOMATION_OWNED_PRINCIPAL_ID']) `
      -ReceiptJobScheduleId ([string]$EnvironmentValues['AUTOMATION_OWNED_JOB_SCHEDULE_ID']) `
      -AdoptAccountId ([string]$EnvironmentValues['AUTOMATION_ADOPT_ACCOUNT_ID']) `
      -AdoptPrincipalId ([string]$EnvironmentValues['AUTOMATION_ADOPT_PRINCIPAL_ID']) `
      -AdoptJobScheduleId ([string]$EnvironmentValues['AUTOMATION_ADOPT_JOB_SCHEDULE_ID'])
    $association = @($inventory.value | Where-Object { [string]$_.name -ieq $ownership.OwnedJobScheduleId })
    if ($association.Count -ne 1 -or [string]$association[0].id -ine "$id/jobSchedules/$($ownership.OwnedJobScheduleId)" -or
        [string]$association[0].type -ine 'Microsoft.Automation/automationAccounts/jobSchedules') {
      throw 'The custom metadata preservation association does not match its exact account, ID, and type.'
    }
  }
  if ($Kind -eq 'FunctionApp' -and [string]$resource.kind -notmatch '(^|,)functionapp(,|$)') {
    throw "The deployed resource '$name' is not a Function App."
  }
  return $resource
}
