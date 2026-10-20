param([string]$RunbookPath, [string]$Fixtures, [string]$ResultPath, [string]$Mode = 'policy', [switch]$RequireNoMail, [switch]$RuntimeOnly, [switch]$NoCorrelation, [string]$ArchiveContainer = 'archive', [string]$LatestContainer = 'latest', [string]$StorageName = '')
$ErrorActionPreference = 'Stop'
Microsoft.PowerShell.Core\Import-Module Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility
Microsoft.PowerShell.Core\Import-Module Pester -RequiredVersion 6.2.0
. (Join-Path $PSScriptRoot 'AssessmentEvidence.ps1')
$global:assessmentProbe = @{
  Imports = [Collections.Generic.List[string]]::new(); Auth = 0; Invokes = 0
  Uploads = [Collections.Generic.List[string]]::new(); Output = [Collections.Generic.List[object]]::new()
  UploadedFiles = [Collections.Generic.List[object]]::new(); TokenRequests = 0; PrivacyRequests = 0
  Mail = ''; Error = ''; ErrorDetails = ''; Drift = ''
}
$locks = Get-Content (Join-Path $Fixtures 'locks.json') -Raw | ConvertFrom-Json -AsHashtable
function Invoke-WebRequest {
  [CmdletBinding()]
  param([string]$Uri, [string]$OutFile, [string]$Method, $Headers, [int]$MaximumRedirection, [switch]$SkipHttpErrorCheck, [int]$MaximumRetryCount, [int]$ConnectionTimeoutSeconds, [int]$OperationTimeoutSeconds)
  if ($Method -eq 'Head') {
    $assessmentProbe.PrivacyRequests++
    if ($Uri -cnotmatch '^https://offlinestorage\.blob\.core\.windows\.net/(archive|private-custom)\?restype=container$' -or $MaximumRedirection -ne 0 -or $MaximumRetryCount -ne 0 -or $ConnectionTimeoutSeconds -ne 10 -or $OperationTimeoutSeconds -ne 15 -or -not $SkipHttpErrorCheck -or $Headers['x-ms-version'] -cne '2021-12-02' -or $Headers.Authorization -cne 'Bearer offline-token' -or $Headers['x-ms-date'] -notmatch 'GMT\z') { throw 'OFFLINE_UNEXPECTED_PRIVACY_CHECK' }
    if ($Mode -eq 'diagnostic-head-throw') { Write-Warning 'PRIVATE_HEAD_WARNING'; throw 'PRIVATE_HEAD_DIAGNOSTIC' }
    $status = if ($Mode -eq 'diagnostic-head-denied') { 403 } elseif ($Mode -eq 'diagnostic-head-redirect') { 302 } else { 200 }
    $responseHeaders = if ($Mode -in @('diagnostic-public-container','diagnostic-public-empty-header')) { @{ 'X-Ms-Blob-Public-Access' = 'blob' } } else { @{} }
    if ($Mode -eq 'diagnostic-public-empty-header') { $responseHeaders['X-Ms-Blob-Public-Access'] = '' }
    if ($Mode -eq 'diagnostic-head-malformed') { $responseHeaders = 'untrusted malformed response' }
    return [pscustomobject]@{ StatusCode = $status; Headers = $responseHeaders }
  }
  if ($Uri -notmatch '^https://www\.powershellgallery\.com/api/v2/package/([^/]+)/([^/]+)$') { throw 'OFFLINE_UNEXPECTED_TRANSPORT' }
  $name = $Matches[1]; $version = $Matches[2]
  if (-not $locks.ContainsKey($name) -or $version -ne $locks[$name].Version) { throw 'OFFLINE_UNEXPECTED_PACKAGE' }
  Copy-Item (Join-Path $Fixtures "$name.$version.nupkg") $OutFile
}
function Get-FileHash {
  [CmdletBinding()]
  param([string]$LiteralPath, [string]$Algorithm)
  if ($LiteralPath.EndsWith('.nupkg')) {
    foreach ($name in $locks.Keys) {
      if ([IO.Path]::GetFileName($LiteralPath) -ceq "$name.$($locks[$name].Version).nupkg") {
        return [pscustomobject]@{ Hash = $locks[$name].Hash }
      }
    }
    throw 'OFFLINE_UNEXPECTED_HASH'
  }
  Microsoft.PowerShell.Utility\Get-FileHash @PSBoundParameters
}
function Import-Module {
  [CmdletBinding()]
  param([string]$Name, [switch]$Force, [switch]$PassThru)
  $moduleName = [IO.Path]::GetFileNameWithoutExtension($Name)
  $assessmentProbe.Imports.Add($moduleName)
  if ($moduleName -eq 'Pester') {
    # Keep real Pester's configuration type loaded. Only this fixture package's
    # import result is substituted; the separate integrity suite checks ZIP hashes.
    return [pscustomobject]@{ Name='Pester'; Version=[version]'6.2.0'; ModuleBase=(Split-Path $Name); Path=$Name }
  }
  Microsoft.PowerShell.Core\Import-Module @PSBoundParameters
}
function Connect-AzAccount { param([switch]$Identity); $assessmentProbe.Auth++ }
function Connect-MgGraph { param([switch]$Identity,[switch]$NoWelcome); $assessmentProbe.Auth++ }
function Get-MgContext { [pscustomobject]@{ TenantId = 'private-fixture-tenant' } }
function Get-AutomationVariable {
  param($Name)
  switch ($Name) {
    'StorageAccountName' { if ($Mode -notin @('no-storage','engine-no-storage')) { 'offlinestorage' } }
    'MailRecipient' { if ($Mode -in @('mail','mail-runtime-error')) { 'private-recipient@example.invalid' } }
    'WebAppName' { if ($Mode -in @('webapp','webapp-failure','webapp-incomplete','engine-error')) { 'offlineweb' } }
    'WebAppResourceGroupName' { if ($Mode -in @('webapp','webapp-failure','engine-error')) { 'offlinerg' } }
    'IncludeExchange' { if ($Mode -eq 'optional') { 'true' } else { 'false' } }
    'IncludeTeams' { if ($Mode -eq 'optional') { 'true' } else { 'false' } }
    'IncludeAzure' { 'false' }
    default { throw 'OFFLINE_UNEXPECTED_VARIABLE' }
  }
}
function Get-AzAccessToken {
  param($ResourceUrl,[switch]$AsSecureString)
  $assessmentProbe.TokenRequests++
  if ($Mode -eq 'diagnostic-token-failure') { Write-Warning 'PRIVATE_TOKEN_WARNING'; throw 'PRIVATE_TOKEN_DIAGNOSTIC' }
  [pscustomobject]@{ Token = (ConvertTo-SecureString 'offline-token' -AsPlainText -Force) }
}
function Invoke-MgGraphRequest { param($Method,$Uri); [pscustomobject]@{ value=@() } }
function Connect-ExchangeOnline { param([switch]$ManagedIdentity,[switch]$ShowBanner,$Organization,$ConnectionUri) }
function Connect-MicrosoftTeams { param([switch]$Identity,$TenantId) }
function Start-Sleep { throw 'OFFLINE_UNEXPECTED_SLEEP' }
function Install-Module { throw 'OFFLINE_UNEXPECTED_INSTALL' }
function Invoke-RestMethod {
  [CmdletBinding()]
  param($Method,$Uri,$Headers,$InFile,$ContentType, [int]$MaximumRetryCount, [int]$ConnectionTimeoutSeconds, [int]$OperationTimeoutSeconds, [int]$MaximumRedirection)
  if ($Method -ne 'Put' -or $Uri -notmatch '^https://(offlinestorage\.blob\.core\.windows\.net/(archive|private-custom|latest)/|offlineweb\.scm\.azurewebsites\.net/api/vfs/site/wwwroot/index\.html)') { throw 'OFFLINE_UNEXPECTED_REST' }
  if ($Uri -match '/failed/' -and ($Headers['x-ms-date'] -notmatch 'GMT\z' -or $MaximumRedirection -ne 0 -or $MaximumRetryCount -ne 0 -or $ConnectionTimeoutSeconds -ne 10 -or $OperationTimeoutSeconds -ne 30)) { throw 'OFFLINE_UNBOUNDED_DIAGNOSTIC_UPLOAD' }
  $assessmentProbe.Uploads.Add($Uri)
  $assessmentProbe.UploadedFiles.Add([pscustomobject]@{ Uri=$Uri; ContentType=$ContentType; Content=[IO.File]::ReadAllText($InFile); Length=(Get-Item -LiteralPath $InFile).Length })
  if ($Mode -eq 'diagnostic-upload-failure' -and $Uri -match '/failed/') { Write-Warning 'PRIVATE_UPLOAD_WARNING'; throw 'PRIVATE_UPLOAD_DIAGNOSTIC' }
  if (($Mode -eq 'archive-failure' -and $Uri -match '/archive/') -or ($Mode -eq 'latest-failure' -and $Uri -match '/latest/') -or ($Mode -eq 'webapp-failure' -and $Uri -match '\.scm\.')) { throw 'PRIVATE_UPLOAD_DIAGNOSTIC' }
}
function Invoke-Maester {
  [CmdletBinding()]
  param($Path,$OutputFolder,$OutputFolderFileName,[switch]$PassThru,[switch]$NonInteractive,[switch]$DisableTelemetry,[switch]$SkipVersionCheck,$PesterConfiguration,$MailRecipient,$MailUserId)
  $assessmentProbe.Invokes++
  $assessmentProbe.Mail = [string]$MailRecipient
  $assessmentProbe.Drift = [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT','Process')
  if (-not $PassThru -or -not $NonInteractive -or -not $DisableTelemetry -or -not $SkipVersionCheck -or $OutputFolderFileName -cne 'assessment') { throw 'OFFLINE_INVOKE_CONTRACT' }
  if ($PesterConfiguration.TestResult.OutputFormat.Value -cne 'JUnitXml' -or -not $PesterConfiguration.TestResult.Enabled.Value) { throw 'OFFLINE_JUNIT_CONTRACT' }
  if ($Mode -eq 'throw') { throw 'PRIVATE_INVOCATION_DIAGNOSTIC' }
  if ($Mode -eq 'nonterminating') { Write-Error 'PRIVATE_NONTERMINATING_DIAGNOSTIC' }
  if ($Mode -eq 'policy') { try { 1 | Should -Be 2 -ErrorAction Stop } catch { } }
  if ($Mode -like 'engine-*' -or $Mode -like 'diagnostic-*') {
    try { throw [IO.IOException]::new('PRIVATE_ENGINE_CAUSE') } catch { }
  }
  Write-Host 'PRIVATE_INFORMATION_DIAGNOSTIC'
  Write-Warning 'PRIVATE_WARNING_DIAGNOSTIC'
  $result = New-TestAssessmentResult $Path
  $reportPath = Join-Path $OutputFolder 'assessment.html'
  $result | Add-Member OutputFiles ([pscustomobject]@{ OutputHtmlFile = $reportPath })
  if ($Mode -ne 'no-report') { Set-Content $reportPath '<html>private policy findings</html>' }
  if ($Mode -eq 'wrong-report') { $result.OutputFiles.OutputHtmlFile = Join-Path $OutputFolder 'older.html'; Set-Content $result.OutputFiles.OutputHtmlFile '<html>older</html>' }
  if ($Mode -eq 'stale-html-only') { return 'old success text' }
  if ($Mode -eq 'duplicate-result') { Write-Output $result }
  if ($Mode -eq 'zero') { $result.Tests=@(); $result.TotalCount=0; $result.PassedCount=0; $result.FailedCount=0; $result.SkippedCount=0; $result.NotRunCount=0 }
  if ($Mode -eq 'maester-error') { $result.Tests[1].Result='Error'; $result.ErrorCount=1; $result.FailedCount=0 }
  if ($Mode -in @('runtime-error','mail-runtime-error')) { $result.Tests[1].ErrorRecord=@([pscustomobject]@{ FullyQualifiedErrorId='System.IO.IOException'; Exception='private-runtime-diagnostic' }) }
  if ($Mode -eq 'core-missing') { $result.Tests[0].Id='other' }
  if ($Mode -notin @('no-junit','engine-no-junit','engine-wrong-junit')) {
    $engineErrors = if ($Mode -like 'engine-*' -or $Mode -like 'diagnostic-*') { 1 } else { 0 }
    Set-Content $PesterConfiguration.TestResult.OutputPath.Value "<testsuites tests=`"5`" errors=`"$engineErrors`" failures=`"1`" disabled=`"3`" />"
  }
  switch ($Mode) {
    'engine-wrong-junit' { Set-Content (Join-Path $OutputFolder 'older-junit.xml') '<testsuites tests="5" errors="1" failures="1" disabled="3" />' }
    'engine-oversized-junit' { [IO.File]::WriteAllText($PesterConfiguration.TestResult.OutputPath.Value, ' ' * 16777217) }
    'engine-directory-junit' { Remove-Item $PesterConfiguration.TestResult.OutputPath.Value; New-Item -ItemType Directory $PesterConfiguration.TestResult.OutputPath.Value | Out-Null }
    'engine-symlink-junit' { Move-Item $PesterConfiguration.TestResult.OutputPath.Value (Join-Path $OutputFolder 'linked.xml'); New-Item -ItemType SymbolicLink -Path $PesterConfiguration.TestResult.OutputPath.Value -Target (Join-Path $OutputFolder 'linked.xml') | Out-Null }
  }
  $result
}
if ($Mode -eq 'diagnostic-projection-failure') { function ConvertTo-Json { throw 'PRIVATE_PROJECTION_DIAGNOSTIC' } }
try {
  $parameters = @{ RequireNoMail = [bool]$RequireNoMail; ExportContainer = $ArchiveContainer; DashboardContainer = $LatestContainer }
  if ($StorageName) { $parameters.StorageAccountName = $StorageName }
  if (-not $NoCorrelation) { $parameters.ValidationJobId = '11111111-1111-4111-8111-111111111111' }
  if ($RuntimeOnly) { $parameters.RuntimeValidationOnly = $true }
  [Environment]::SetEnvironmentVariable('MAESTER_FOLDER_DRIFT', 'unapproved-inherited-drift', 'Process')
  & $RunbookPath @parameters | ForEach-Object { $assessmentProbe.Output.Add($_) }
}
catch { $assessmentProbe.Error = $_.Exception.Message; $assessmentProbe.ErrorDetails = $_.ScriptStackTrace }
finally {
  $assessmentProbe.RestoredDrift = [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT','Process')
  $assessmentProbe | Microsoft.PowerShell.Utility\ConvertTo-Json -Depth 10 | Set-Content $ResultPath
}
if ($assessmentProbe.Error) { exit 1 }
