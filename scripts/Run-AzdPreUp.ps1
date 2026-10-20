#Requires -Version 7.6
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'vendor\Azd.MaesterHooks\Maester-PreUp.psm1') -Force

Invoke-MaesterPreUp -ProjectRoot (Split-Path $PSScriptRoot -Parent) `
  -EnvironmentName $env:AZURE_ENV_NAME -SolutionName 'automation-account'
