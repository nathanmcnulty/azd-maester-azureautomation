# Shared preprovision helpers for azd-maester solutions.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Maester-UpWizard.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Maester-SetupHelpers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Maester-InfrastructureOwnership.psm1')

function Get-SemanticVersion {
  param([Parameter(Mandatory = $true)][string]$VersionText)

  $match = [regex]::Match($VersionText, '(\d+)\.(\d+)\.(\d+)')
  if (-not $match.Success) {
    return $null
  }

  return [version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value)
}

function Invoke-MaesterPreProvision {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('automation-account', 'function-app', 'container-app-job', 'azure-devops')]
    [string]$SolutionName,

    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][string]$EnvironmentName,
    [switch]$Configure,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [switch]$RequireGit,

    [Parameter(Mandatory = $false)]
    [switch]$RequireAdopsModule
  )

  # Resolve from the named environment, never ambient azd selection or a cached account.
  $target = Resolve-MaesterInfrastructureContext -ProjectRoot $ProjectRoot -EnvironmentName $EnvironmentName `
    -SolutionName $SolutionName -SubscriptionId $SubscriptionId -TenantId $TenantId
  $SubscriptionId = $target.binding.subscriptionId
  $TenantId = $target.binding.tenantId
  if ($Location -and $Location -ine $target.values['AZURE_LOCATION']) {
    throw 'Explicit location differs from the selected azd environment.'
  }
  $Location = [string]$target.values['AZURE_LOCATION']
  if ([string]::IsNullOrWhiteSpace($Location)) { $Location = 'eastus2' }

  # Postprovision is a separate process: a Graph context here is not readiness
  # evidence. Its existing consent flow must be able to ask for login approval.
  # The existing Automation preservation mode does not run Graph setup.
  $preserveAccess = $false
  if ($SolutionName -eq 'automation-account') {
    $selected = [string]$target.values['AUTOMATION_UPGRADE_PRESERVE_ACCESS']
    $ambient = $env:AUTOMATION_UPGRADE_PRESERVE_ACCESS
    if ($ambient -and $ambient -ine $selected) { throw 'The process AUTOMATION_UPGRADE_PRESERVE_ACCESS differs from the selected azd environment.' }
    if ($selected -and $selected -notin @('true', 'false')) { throw 'AUTOMATION_UPGRADE_PRESERVE_ACCESS must be true or false.' }
    $preserveAccess = $selected -eq 'true'
  }
  if (-not $preserveAccess -and -not (Test-InteractiveWizard)) {
    throw 'Postprovision setup requires interactive login approval in its own process. Run the preup preparation interactively before provisioning; no ARM create was attempted by this hook.'
  }

  $azdVersionOutput = (& azd version) -join "`n"
  $detectedVersion = Get-SemanticVersion -VersionText $azdVersionOutput
  $minimumVersion = [version]::new(1, 23, 5)
  if (-not $detectedVersion) {
    Write-Warning 'Could not parse azd version. Continuing with preprovision checks.'
  }
  elseif ($detectedVersion -lt $minimumVersion) {
    throw "azd version $detectedVersion detected. Version 1.23.5 or newer is required for this template flow."
  }

  if ($RequireGit -and -not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is required for Azure DevOps repository bootstrap but was not found on PATH.'
  }

  if ($RequireAdopsModule) {
    Import-Module (Join-Path $PSScriptRoot 'Maester-SetupHelpers.psm1') -Force

    $adopsInstallMessage = "PowerShell module 'ADOPS' is required for Azure DevOps integration. Install now to continue preprovision checks."
    if (-not (Test-ModuleAvailable -ModuleName 'ADOPS' -InstallMessage $adopsInstallMessage)) {
      throw "PowerShell module 'ADOPS' is required. Install with: Install-Module ADOPS -Scope CurrentUser -Force -AllowClobber"
    }
  }

  Push-Location -LiteralPath $target.root
  try {
    Invoke-MaesterUpWizard -SolutionName $SolutionName -SubscriptionId $SubscriptionId `
      -Location $Location -TenantId $TenantId -EnvironmentName $EnvironmentName -UseSavedConfiguration:(-not $Configure -or $preserveAccess)
  } finally { Pop-Location }

  $prepared = Resolve-MaesterInfrastructureContext -ProjectRoot $ProjectRoot -EnvironmentName $EnvironmentName `
    -SolutionName $SolutionName -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroupName $target.resourceGroupName
  if ($prepared.values['AZURE_LOCATION'] -ine $Location) { throw 'The wizard changed the selected deployment location.' }
  # Initialize only after all prerequisite checks and wizard validation. Its live
  # 404 -> durable Pending -> exact PUT 201 -> Created proof is unchanged.
  Initialize-MaesterInfrastructureOwnership -ProjectRoot $prepared.root -EnvironmentName $EnvironmentName `
    -SolutionName $SolutionName -SubscriptionId $SubscriptionId -TenantId $TenantId `
    -ResourceGroupName $prepared.resourceGroupName -RequireExisting:$preserveAccess | Out-Null
  Write-Host 'Maester selected-target prerequisites and infrastructure ownership preflight passed.'
}

Export-ModuleMember -Function Invoke-MaesterPreProvision
