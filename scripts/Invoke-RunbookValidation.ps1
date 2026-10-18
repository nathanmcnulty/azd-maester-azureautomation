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

  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'vendor\Azd.MaesterHooks\Maester-SetupHelpers.psm1') -Force

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

$jobParameters = @{}
if ($RuntimeValidationOnly) {
  # ARM job parameter values are strings containing JSON-serialized values.
  # The service deserializes this to the runbook's Boolean, not string truthiness.
  $jobParameters.RuntimeValidationOnly = ($true | ConvertTo-Json -Compress)
}

$jobBody = @{
  properties = @{
    runbook = @{
      name = $RunbookName
    }
    parameters = $jobParameters
  }
} | ConvertTo-Json -Depth 10 -Compress

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

$streams = @()
$streamsUrl = "https://management.azure.com$basePath/jobs/${jobId}/streams?api-version=$apiVersion"
do {
  $streamsPayload = Invoke-RestMethod -Method GET -Uri $streamsUrl -Headers $armHeaders
  $hasValueProperty = $false
  $hasNextLinkProperty = $false
  if ($streamsPayload -and $streamsPayload.PSObject) {
    $hasValueProperty = $streamsPayload.PSObject.Properties.Match('value').Count -gt 0
    $hasNextLinkProperty = $streamsPayload.PSObject.Properties.Match('nextLink').Count -gt 0
  }

  if ($streamsPayload -is [System.Array]) {
    $streams += $streamsPayload
    $nextLink = $null
  }
  elseif ($hasValueProperty -and $streamsPayload.value) {
    $streams += $streamsPayload.value
    $nextLink = if ($hasNextLinkProperty) { $streamsPayload.nextLink } else { $null }
  }
  else {
    $nextLink = $null
  }
  if ($nextLink) {
    $streamsUrl = if ($nextLink -like 'https://*') {
      $nextLink
    }
    else {
      "https://management.azure.com$nextLink"
    }
  }
} while ($nextLink)

foreach ($stream in $streams) {
  $streamType = $stream.properties.streamType
  $streamId = if ($stream.properties.jobStreamId) { $stream.properties.jobStreamId } else { ($stream.id -split '/')[-1] }
  $detail = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$basePath/jobs/${jobId}/streams/${streamId}?api-version=$apiVersion" -Headers $armHeaders
  Write-Host "[$streamType] $($detail.properties.summary)"
}

if ($status -ne 'Completed') {
  $job = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$basePath/jobs/${jobId}?api-version=$apiVersion" -Headers $armHeaders
  $exception = $job.properties.exception
  if ($exception) {
    throw "Runbook job did not complete successfully. Final status: $status. Exception: $exception"
  }
  throw "Runbook job did not complete successfully. Final status: $status"
}

Write-Host 'Runbook validation completed successfully.'

$result = [pscustomobject]@{
  ValidationPassed      = $true
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
