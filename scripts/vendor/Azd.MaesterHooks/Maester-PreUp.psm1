# Run before native azd provider initialization, which can create a resource group.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Maester-PreProvision.psm1')

function Invoke-MaesterPreUp {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)]
    [ValidateSet('automation-account', 'function-app', 'container-app-job', 'azure-devops')]
    [string]$SolutionName,
    [switch]$RequireGit,
    [switch]$RequireAdopsModule
  )
  Invoke-MaesterPreProvision @PSBoundParameters -Configure
}
Export-ModuleMember -Function Invoke-MaesterPreUp
