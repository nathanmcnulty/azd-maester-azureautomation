#Requires -Version 7.6
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [string]$TenantId,

  [Parameter(Mandatory = $true)]
  [string]$ResourceGroupName,

  [Parameter(Mandatory = $true)]
  [string]$AutomationAccountName,

  [string]$RunbookName = 'maester-runbook',

  [int]$TimeoutMinutes = 20,

  [switch]$RuntimeValidationOnly,

  # Retained for existing diagnostic callers; the runbook host policy no longer needs it.
  [switch]$AllowRuntimeValidationPreview,

  # Qualification is explicit. The runbook rejects configured mail before invocation.
  [switch]$RequireNoMail,
  [switch]$ExpectWebApp,
  [switch]$ExpectExchangeImport,
  [switch]$ExpectTeamsImport,

  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($AllowRuntimeValidationPreview -and -not $RuntimeValidationOnly) {
  throw 'AllowRuntimeValidationPreview requires RuntimeValidationOnly.'
}

if ($RuntimeValidationOnly -and ($RequireNoMail -or $ExpectWebApp -or $ExpectExchangeImport -or $ExpectTeamsImport)) {
  throw 'RuntimeValidationOnly cannot include assessment, publication, or optional-import expectations.'
}

Import-Module (Join-Path $PSScriptRoot 'vendor\Azd.MaesterHooks\Maester-SetupHelpers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Maester.AutomationEvidence.psm1') -Force

if (-not $TenantId -and $env:AZURE_TENANT_ID) { $TenantId = $env:AZURE_TENANT_ID }
if ([string]::IsNullOrWhiteSpace($TenantId)) {
  throw 'TenantId is required. Pass -TenantId or set AZURE_TENANT_ID to the expected tenant.'
}

$azAccount = Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId
$TenantId = $azAccount.tenantId
$armToken = Get-AzCliAccessToken -SubscriptionId $SubscriptionId -TenantId $TenantId -Resource 'https://management.azure.com/'
if ([string]::IsNullOrWhiteSpace($armToken)) { throw 'ARM token acquisition failed for the validated target.' }
$armHeaders = @{ Authorization = "Bearer $armToken" }

$apiVersion = '2023-11-01'
$jobId = [guid]::NewGuid().ToString()
$basePath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName"

$expectedContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-MaesterAutomationRunbook.ps1') -Raw
$jobParameters = @{}
if (-not $RuntimeValidationOnly) {
  $jobParameters.ValidationJobId = ($jobId | ConvertTo-Json -Compress)
  if ($RequireNoMail) { $jobParameters.RequireNoMail = ($true | ConvertTo-Json -Compress) }
}
if ($RuntimeValidationOnly) {
  # ARM job parameter values are strings containing JSON-serialized values.
  # The service deserializes this to the runbook's Boolean, not string truthiness.
  $jobParameters.RuntimeValidationOnly = ($true | ConvertTo-Json -Compress)
}

if ($AllowRuntimeValidationPreview) {
  $jobParameters.AllowRuntimeValidationPreview = ($true | ConvertTo-Json -Compress)
}

$jobBody = @{
  properties = @{
    runbook = @{
      name = $RunbookName
    }
    parameters = $jobParameters
  }
} | ConvertTo-Json -Depth 10 -Compress

$startedAt = [datetimeoffset]::UtcNow
Invoke-RestMethod -Method PUT -Uri "https://management.azure.com$basePath/jobs/${jobId}?api-version=$apiVersion" -Headers $armHeaders -Body $jobBody -ContentType 'application/json' | Out-Null
Write-Host "Started runbook job: $jobId"

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$status = 'New'
do {
  Start-Sleep -Seconds 15
  $job = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$basePath/jobs/${jobId}?api-version=$apiVersion" -Headers $armHeaders
  $status = $job.properties.status
  Write-Host "Job status: $status"
} while ($status -in @('New', 'Activating', 'Running', 'Queued') -and (Get-Date) -lt $deadline)

if ($status -ne 'Completed') {
  # Do not replay service exceptions or private assessment stream diagnostics.
  throw "Runbook job did not complete successfully. Final status: $status"
}

# These documented read endpoints are bound to the created job, not whichever
# runbook version is published now. No added role or data-plane grant is needed.
try {
  $output = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$basePath/jobs/${jobId}/output?api-version=$apiVersion" -Headers $armHeaders
  $jobContent = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$basePath/jobs/${jobId}/runbookContent?api-version=$apiVersion" -Headers $armHeaders
}
catch { throw 'validation.jobEvidenceUnavailable: existing Automation job output/content read access is required; no permissions were changed.' }
$evidence = Read-AutomationJobEvidence -Output $output -JobContent $jobContent -ExpectedContent $expectedContent -JobId $jobId -NotBefore $startedAt -RuntimeValidationOnly:$RuntimeValidationOnly -RequireNoMail:$RequireNoMail -ExpectWebApp:$ExpectWebApp -ExpectExchangeImport:$ExpectExchangeImport -ExpectTeamsImport:$ExpectTeamsImport
Write-Host "Runbook evidence verified. Scope: $($evidence.Scope)."

$result = [pscustomobject]@{
  ValidationPassed      = $true
  ValidationScope       = $evidence.Scope
  Evidence              = $evidence
  JobId                 = $jobId
  FinalStatus           = $status
  SubscriptionId        = $SubscriptionId
  ResourceGroupName     = $ResourceGroupName
  AutomationAccountName = $AutomationAccountName
  RunbookName           = $RunbookName
  CompletedAt           = (Get-Date).ToString('o')
}

if ($PassThru) {
  return $result
}
