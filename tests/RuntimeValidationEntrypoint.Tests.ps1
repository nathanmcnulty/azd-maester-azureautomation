Describe 'Runtime validation through the maintained runbook entrypoint' {
  BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $runbookPath = Join-Path $repoRoot 'scripts/Invoke-MaesterAutomationRunbook.ps1'
    $runbookText = Get-Content -LiteralPath $runbookPath -Raw
    $requiredModules = @('NuGet', 'PackageManagement', 'PowerShellGet', 'Az.Accounts', 'Microsoft.Graph.Authentication', 'Pester', 'Maester')
    $locks = @{}
    foreach ($match in [regex]::Matches($runbookText, "'(?<Name>[A-Za-z0-9.]+)' = @\{ Version = '(?<Version>[0-9.]+)'; Sha256 = '(?<Hash>[A-F0-9]{64})' \}")) {
      $locks[$match.Groups['Name'].Value] = @{
        Version = $match.Groups['Version'].Value
        Hash = $match.Groups['Hash'].Value
      }
    }
    $fixtures = Join-Path $TestDrive 'fixtures'
    New-Item -ItemType Directory -Path $fixtures | Out-Null
    foreach ($name in $requiredModules) {
      if (-not $locks.ContainsKey($name)) { throw "Expected package lock is missing: $name" }
      $source = Join-Path $fixtures $name
      New-Item -ItemType Directory -Path $source | Out-Null
      $version = $locks[$name].Version
      Set-Content -LiteralPath (Join-Path $source "$name.psd1") -Value "@{RootModule='$name.psm1'; ModuleVersion='$version'; GUID='$([guid]::NewGuid())'; FunctionsToExport=@(); CmdletsToExport=@(); AliasesToExport=@()}"
      Set-Content -LiteralPath (Join-Path $source "$name.psm1") -Value 'Export-ModuleMember -Function @() -Cmdlet @() -Alias @()'
      [IO.Compression.ZipFile]::CreateFromDirectory($source, (Join-Path $fixtures "$name.$version.nupkg"))
    }
    $noManifest = Join-Path $fixtures 'no-manifest'
    New-Item -ItemType Directory -Path $noManifest | Out-Null
    Set-Content -LiteralPath (Join-Path $noManifest 'README.txt') -Value 'Package deliberately has no module manifest.'
    [IO.Compression.ZipFile]::CreateFromDirectory($noManifest, (Join-Path $fixtures 'no-manifest.nupkg'))
    $locks | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $fixtures 'locks.json')

    # Invoke the actual .ps1 file, never an extracted or rewritten probe block.
    # Each child is isolated from Pester and all transports fail closed. Tiny ZIPs
    # exercise extraction and real Import-Module; only their pinned hash result is
    # substituted. RunbookPackageIntegrity.Tests.ps1 covers real SHA-256 bytes.
    $harnessPath = Join-Path $TestDrive 'runtime-entrypoint-harness.ps1'
    Set-Content -LiteralPath $harnessPath -Value @'
param([string]$RunbookPath, [string]$Fixtures, [string]$ResultPath,
      [string]$Mode = 'true', [string]$Failure = '', [string]$FailureModule = 'Maester',
      [string]$RuntimeVersion = '', [string]$RuntimeEdition = '', [string]$RuntimeDotNet = '', [string]$PreviewMode = 'default')
$ErrorActionPreference = 'Stop'
Microsoft.PowerShell.Core\Import-Module Microsoft.PowerShell.Management, Microsoft.PowerShell.Utility
$PSModuleAutoLoadingPreference = 'None'
$global:runtimeProbe_trace = [Collections.Generic.List[object]]::new()
$global:runtimeProbe_outputs = [Collections.Generic.List[object]]::new()
$global:runtimeProbe_locks = Get-Content -LiteralPath (Join-Path $Fixtures 'locks.json') -Raw | ConvertFrom-Json -AsHashtable
$global:runtimeProbe_allowed = @('NuGet', 'PackageManagement', 'PowerShellGet', 'Az.Accounts', 'Microsoft.Graph.Authentication', 'Pester', 'Maester')
$global:runtimeProbe_errorText = $null
$global:runtimeProbe_realVersion = $PSVersionTable.PSVersion.ToString()
$global:runtimeProbe_realDotNet = [System.Environment]::Version.ToString()
function Add-Trace([string]$Kind, [string]$Name, [string]$Path = '') {
  $global:runtimeProbe_trace.Add([pscustomobject]@{ Kind = $Kind; Name = $Name; Path = $Path })
}
function New-Item {
  [CmdletBinding()]
  param($Path, $ItemType, [switch]$Force)
  Add-Trace 'Filesystem' 'New-Item' ([string]$Path)
  Microsoft.PowerShell.Management\New-Item @PSBoundParameters
}
function Invoke-WebRequest {
  [CmdletBinding()]
  param([string]$Uri, [string]$OutFile)
  if ($Uri -notmatch '^https://www\.powershellgallery\.com/api/v2/package/([^/]+)/([^/]+)$') {
    Add-Trace 'Forbidden' 'Invoke-WebRequest' $Uri
    throw "Unexpected transport: $Uri"
  }
  $name = $Matches[1]; $version = $Matches[2]
  if ($name -notin $global:runtimeProbe_allowed -or $version -ne $global:runtimeProbe_locks[$name].Version) {
    Add-Trace 'Forbidden' 'Invoke-WebRequest' $Uri
    throw "Unexpected package transport: $Uri"
  }
  Add-Trace 'Download' $name $OutFile
  if ($name -eq $FailureModule) {
    if ($Failure -eq 'missing') { return }
    if ($Failure -eq 'download') { throw 'OFFLINE_PACKAGE_DOWNLOAD_FAILURE' }
    if ($Failure -eq 'archive') { Set-Content -LiteralPath $OutFile -Value 'not a ZIP archive'; return }
    if ($Failure -eq 'manifest') { Copy-Item -LiteralPath (Join-Path $Fixtures 'no-manifest.nupkg') -Destination $OutFile; return }
  }
  Copy-Item -LiteralPath (Join-Path $Fixtures "$name.$version.nupkg") -Destination $OutFile
}
function Get-FileHash {
  [CmdletBinding()]
  param([string]$LiteralPath, [string]$Algorithm)
  if ($Algorithm -ne 'SHA256' -or -not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
    throw 'Hash verifier was called without an existing SHA-256 package.'
  }
  $download = @($global:runtimeProbe_trace | Where-Object { $_.Kind -eq 'Download' -and $_.Path -eq $LiteralPath })
  if ($download.Count -ne 1) { throw 'Hash verifier received an unexpected package path.' }
  $name = $download[0].Name
  Add-Trace 'Hash' $name $LiteralPath
  if ($name -eq $FailureModule -and $Failure -eq 'hash') { return [pscustomobject]@{ Hash = ('0' * 64) } }
  [pscustomobject]@{ Hash = $global:runtimeProbe_locks[$name].Hash }
}
function Import-Module {
  [CmdletBinding()]
  param([string]$Name, [switch]$Force, [switch]$PassThru)
  $moduleName = [IO.Path]::GetFileNameWithoutExtension($Name)
  $moduleBase = Split-Path $Name -Parent
  Add-Trace 'Import' $moduleName $Name
  if ($moduleName -notin $global:runtimeProbe_allowed -or -not $Force -or -not $PassThru -or
      $PSBoundParameters['ErrorAction'] -ne 'Stop' -or -not (Test-Path -LiteralPath $Name -PathType Leaf)) {
    throw 'Unexpected module import boundary.'
  }
  if ($moduleName -eq $FailureModule -and $Failure -eq 'import') { throw 'OFFLINE_MODULE_IMPORT_FAILURE' }
  if ($moduleName -eq $FailureModule -and $Failure -in @('name', 'version', 'base')) {
    return [pscustomobject]@{
      Name = $(if ($Failure -eq 'name') { 'Unexpected.Module' } else { $moduleName })
      Version = $(if ($Failure -eq 'version') { [version]'0.0.1' } else { [version]$global:runtimeProbe_locks[$moduleName].Version })
      ModuleBase = $(if ($Failure -eq 'base') { $Fixtures } else { $moduleBase })
      Path = Join-Path $moduleBase "$moduleName.psm1"
    }
  }
  Microsoft.PowerShell.Core\Import-Module @PSBoundParameters
}
function Invoke-Forbidden([string]$Name) {
  Add-Trace 'Forbidden' $Name
  throw "FORBIDDEN_DOWNSTREAM:$Name"
}
function Connect-AzAccount { Invoke-Forbidden 'Connect-AzAccount' }
function Connect-MgGraph { Invoke-Forbidden 'Connect-MgGraph' }
function Get-MgContext { Invoke-Forbidden 'Get-MgContext' }
function Get-AutomationVariable { Invoke-Forbidden 'Get-AutomationVariable' }
function Connect-ExchangeOnline { Invoke-Forbidden 'Connect-ExchangeOnline' }
function Connect-MicrosoftTeams { Invoke-Forbidden 'Connect-MicrosoftTeams' }
function Get-AzAccessToken { Invoke-Forbidden 'Get-AzAccessToken' }
function Invoke-MgGraphRequest { Invoke-Forbidden 'Invoke-MgGraphRequest' }
function Invoke-RestMethod { Invoke-Forbidden 'Invoke-RestMethod' }
function Invoke-Maester { Invoke-Forbidden 'Invoke-Maester' }
function Install-MaesterTests { Invoke-Forbidden 'Install-MaesterTests' }
function Send-MgUserMail { Invoke-Forbidden 'Send-MgUserMail' }
function Start-Sleep { Invoke-Forbidden 'Start-Sleep' }
try {
  # Shadow only the CLR type boundary in this isolated child; invoke the unchanged runbook.
  if ($RuntimeDotNet) {
    Add-Type -TypeDefinition ('public class RuntimeProbeEnvironment { public static System.Version Version = new System.Version("' + $RuntimeDotNet + '"); }')
    [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')::Add('Environment', [RuntimeProbeEnvironment])
  }
  if ($RuntimeVersion) { $PSVersionTable.PSVersion = [System.Management.Automation.SemanticVersion]$RuntimeVersion }
  if ($RuntimeEdition) { $PSVersionTable.PSEdition = $RuntimeEdition }
  $parameters = @{}
  if ($Mode -eq 'true') { $parameters.RuntimeValidationOnly = $true }
  elseif ($Mode -eq 'false') { $parameters.RuntimeValidationOnly = $false }
  elseif ($Mode -in @('string-true', 'string-false')) { $parameters.RuntimeValidationOnly = $Mode.Substring(7) }
  if ($PreviewMode -ne 'default') { $parameters.AllowRuntimeValidationPreview = ($PreviewMode -eq 'true') }
  & $RunbookPath @parameters | ForEach-Object { $global:runtimeProbe_outputs.Add($_) }
}
catch { $global:runtimeProbe_errorText = $_.Exception.Message; $global:runtimeProbe_errorDetails = ($_ | Out-String) + $_.ScriptStackTrace }
finally {
  [pscustomobject]@{
    Output = @($global:runtimeProbe_outputs.ToArray())
    Trace = @($global:runtimeProbe_trace.ToArray())
    Error = $global:runtimeProbe_errorText
    ErrorDetails = $global:runtimeProbe_errorDetails
    ActualPowerShellVersion = $global:runtimeProbe_realVersion
    ActualDotNetVersion = $global:runtimeProbe_realDotNet
  } | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $ResultPath
}
if ($global:runtimeProbe_errorText) { exit 1 }
'@

    function Invoke-OfflineRunbook {
      param([string]$Mode = 'true', [string]$Failure = '', [string]$FailureModule = 'Maester',
            [string]$RuntimeVersion = '', [string]$RuntimeEdition = '', [string]$RuntimeDotNet = '', [string]$PreviewMode = 'default')
      $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
      $tempPath = Join-Path $caseRoot 'temp'
      New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
      $resultPath = Join-Path $caseRoot 'result.json'
      $start = [Diagnostics.ProcessStartInfo]::new()
      $start.FileName = (Get-Process -Id $PID).Path
      $start.UseShellExecute = $false
      $start.RedirectStandardOutput = $true
      $start.RedirectStandardError = $true
      $start.Environment['TMPDIR'] = $tempPath
      $start.Environment['TEMP'] = $tempPath
      $start.Environment['TMP'] = $tempPath
      foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $harnessPath,
          '-RunbookPath', $runbookPath, '-Fixtures', $fixtures, '-ResultPath', $resultPath,
          '-Mode', $Mode, '-Failure', $Failure, '-FailureModule', $FailureModule,
          '-RuntimeVersion', $RuntimeVersion, '-RuntimeEdition', $RuntimeEdition, '-RuntimeDotNet', $RuntimeDotNet, '-PreviewMode', $PreviewMode)) {
        $start.ArgumentList.Add($argument)
      }
      $process = [Diagnostics.Process]::Start($start)
      try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill($true); throw 'Offline runbook harness did not finish within 30 seconds.' }
        if (-not (Test-Path -LiteralPath $resultPath)) {
          throw "Offline harness did not write its result. $($stdout.Result) $($stderr.Result)"
        }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        $result | Add-Member -NotePropertyName ExitCode -NotePropertyValue $process.ExitCode
        $result | Add-Member -NotePropertyName CaseRoot -NotePropertyValue $caseRoot
        $result
      }
      finally { $process.Dispose() }
    }

    function Assert-NoValidationReceipt($Result) {
      @($Result.Output | Where-Object { $_ -match '"Kind"\s*:\s*"Maester.RuntimeValidation"' }).Count | Should -Be 0
    }
  }

  It 'imports all seven locked packages and emits one JSON receipt before any downstream work' {
    $result = Invoke-OfflineRunbook
    $result.ExitCode | Should -Be 0 -Because "$($result.Error) $($result.ErrorDetails)"
    $result.Error | Should -BeNullOrEmpty
    @($result.Trace | Where-Object Kind -eq 'Forbidden').Count | Should -Be 0
    foreach ($kind in 'Download', 'Hash', 'Import') {
      (@($result.Trace | Where-Object Kind -eq $kind).Name -join ',') | Should -Be ($requiredModules -join ',')
    }
    $receipts = @($result.Output | Where-Object { $_ -match '^\{' } | ForEach-Object { $_ | ConvertFrom-Json })
    $receipts.Count | Should -Be 1
    $receipt = $receipts[0]
    $receipt.Kind | Should -Be 'Maester.RuntimeValidation'
    $receipt.SchemaVersion | Should -Be 1
    $receipt.PowerShellVersion | Should -Be $result.ActualPowerShellVersion
    [version]$receipt.PowerShellVersion | Should -BeGreaterOrEqual ([version]'7.6')
    $receipt.DotNetVersion | Should -Be $result.ActualDotNetVersion
    ([version]$receipt.DotNetVersion).Major | Should -BeGreaterOrEqual 10
    @($receipt.Modules).Count | Should -Be 7
    ($receipt.Modules.Name -join ',') | Should -Be ($requiredModules -join ',')
    foreach ($module in $receipt.Modules) {
      $module.Version | Should -Be $locks[$module.Name].Version
      $import = @($result.Trace | Where-Object { $_.Kind -eq 'Import' -and $_.Name -eq $module.Name })
      $import.Count | Should -Be 1
      $module.ModuleBase | Should -Be (Split-Path $import[0].Path -Parent)
      $module.Path | Should -Be (Join-Path $module.ModuleBase "$($module.Name).psm1")
      Test-Path -LiteralPath $module.Path -PathType Leaf | Should -BeTrue
      $module.Path.StartsWith($result.CaseRoot, [StringComparison]::Ordinal) | Should -BeTrue
    }
    @($result.Trace | Where-Object { $_.Name -in @('ExchangeOnlineManagement', 'MicrosoftTeams') }).Count | Should -Be 0
  }

  It 'preserves the ordinary first-authentication path when validation is <Mode>' -ForEach @(
    @{ Mode = 'omitted' }, @{ Mode = 'false' }
  ) {
    $result = Invoke-OfflineRunbook -Mode $Mode
    $result.ExitCode | Should -Be 1
    $result.Error | Should -Be 'FORBIDDEN_DOWNSTREAM:Connect-AzAccount'
    (@($result.Trace | Where-Object Kind -eq 'Import').Name -join ',') | Should -Be ($requiredModules -join ',')
    (@($result.Trace | Where-Object Kind -eq 'Forbidden').Name -join ',') | Should -Be 'Connect-AzAccount'
    Assert-NoValidationReceipt $result
  }

  It 'rejects the untyped <Mode> value before any runbook work' -ForEach @(
    @{ Mode = 'string-true' }, @{ Mode = 'string-false' }
  ) {
    $result = Invoke-OfflineRunbook -Mode $Mode
    $result.ExitCode | Should -Be 1
    $result.Error | Should -Match 'RuntimeValidationOnly'
    $result.Error | Should -Match 'Boolean'
    @($result.Trace).Count | Should -Be 0
    @($result.Output).Count | Should -Be 0
    Assert-NoValidationReceipt $result
  }

  It 'fails closed when required package <FailureModule> is missing' -ForEach @(
    @{ FailureModule = 'NuGet' }, @{ FailureModule = 'PackageManagement' }, @{ FailureModule = 'PowerShellGet' },
    @{ FailureModule = 'Az.Accounts' }, @{ FailureModule = 'Microsoft.Graph.Authentication' },
    @{ FailureModule = 'Pester' }, @{ FailureModule = 'Maester' }
  ) {
    $result = Invoke-OfflineRunbook -Failure missing -FailureModule $FailureModule
    $result.ExitCode | Should -Be 1
    $result.Error | Should -Match 'Locked runtime package .+ is missing\.'
    @($result.Trace | Where-Object { $_.Kind -eq 'Import' -and $_.Name -eq $FailureModule }).Count | Should -Be 0
    @($result.Trace | Where-Object Kind -eq 'Forbidden').Count | Should -Be 0
    Assert-NoValidationReceipt $result
  }

  It 'rejects <Failure> before emitting a receipt or invoking downstream commands' -ForEach @(
    @{ Failure = 'download'; Expected = 'OFFLINE_PACKAGE_DOWNLOAD_FAILURE'; Imports = 0 },
    @{ Failure = 'hash'; Expected = 'failed SHA-256 verification'; Imports = 0 },
    @{ Failure = 'archive'; Expected = '.*'; Imports = 0 },
    @{ Failure = 'manifest'; Expected = 'has no manifest'; Imports = 0 },
    @{ Failure = 'import'; Expected = 'OFFLINE_MODULE_IMPORT_FAILURE'; Imports = 1 },
    @{ Failure = 'name'; Expected = 'was not imported from its verified path'; Imports = 1 },
    @{ Failure = 'version'; Expected = 'was not imported from its verified path'; Imports = 1 },
    @{ Failure = 'base'; Expected = 'was not imported from its verified path'; Imports = 1 }
  ) {
    $result = Invoke-OfflineRunbook -Failure $Failure
    $result.ExitCode | Should -Be 1
    $result.Error | Should -Not -BeNullOrEmpty
    $result.Error | Should -Match $Expected
    @($result.Trace | Where-Object { $_.Kind -eq 'Import' -and $_.Name -eq 'Maester' }).Count | Should -Be $Imports
    @($result.Trace | Where-Object Kind -eq 'Forbidden').Count | Should -Be 0
    $download = @($result.Trace | Where-Object { $_.Kind -eq 'Download' -and $_.Name -eq 'Maester' })
    $download.Count | Should -Be 1
    $moduleTarget = Join-Path (Split-Path $download[0].Path -Parent) "Maester/$($locks.Maester.Version)"
    Test-Path -LiteralPath $moduleTarget | Should -BeFalse
    Assert-NoValidationReceipt $result
  }

  It 'qualifies the observed service host in <Mode> mode with legacy preview flag <PreviewMode>' -ForEach @(
    @{ Mode = 'omitted'; PreviewMode = 'default' },
    @{ Mode = 'omitted'; PreviewMode = 'false' },
    @{ Mode = 'false'; PreviewMode = 'default' },
    @{ Mode = 'false'; PreviewMode = 'false' },
    @{ Mode = 'true'; PreviewMode = 'default' },
    @{ Mode = 'true'; PreviewMode = 'false' },
    @{ Mode = 'true'; PreviewMode = 'true' }
  ) {
    $result = Invoke-OfflineRunbook -Mode $Mode -RuntimeVersion '7.6.0-preview.5' -RuntimeEdition 'Core' -RuntimeDotNet '10.0.9' -PreviewMode $PreviewMode
    foreach ($kind in 'Download', 'Hash', 'Import') {
      (@($result.Trace | Where-Object Kind -eq $kind).Name -join ',') | Should -Be ($requiredModules -join ',')
    }
    if ($Mode -eq 'true') {
      $result.ExitCode | Should -Be 0 -Because $result.Error
      @($result.Trace | Where-Object Kind -eq 'Forbidden').Count | Should -Be 0
      $receipts = @($result.Output | Where-Object { $_ -match '^\{' } | ForEach-Object { $_ | ConvertFrom-Json })
      $receipts.Count | Should -Be 1
      $receipts[0].PowerShellVersion | Should -BeExactly '7.6.0-preview.5'
      $receipts[0].DotNetVersion | Should -BeExactly '10.0.9'
      @($receipts[0].Modules).Count | Should -Be 7
    }
    else {
      # The ordinary entrypoint must still reach authentication, never the diagnostic return.
      $result.ExitCode | Should -Be 1
      $result.Error | Should -Be 'FORBIDDEN_DOWNSTREAM:Connect-AzAccount'
      (@($result.Trace | Where-Object Kind -eq 'Forbidden').Name -join ',') | Should -Be 'Connect-AzAccount'
      Assert-NoValidationReceipt $result
    }
  }

  It 'preserves stable release qualification for <Version> on .NET <DotNet> in <Mode> mode' -ForEach @(
    foreach ($hostCase in @(
      @{ Version = '7.6.0'; DotNet = '10.0.0' },
      @{ Version = '7.6.6'; DotNet = '10.0.12' },
      @{ Version = '7.7.0'; DotNet = '10.0.12' },
      @{ Version = '8.0.0'; DotNet = '11.0.0' },
      @{ Version = '7.6.0+provider.1'; DotNet = '10.0.12' }
    )) {
      foreach ($mode in 'omitted', 'false', 'true') {
        @{ Version = $hostCase.Version; DotNet = $hostCase.DotNet; Mode = $mode }
      }
    }
  ) {
    $result = Invoke-OfflineRunbook -Mode $Mode -RuntimeVersion $Version -RuntimeEdition 'Core' -RuntimeDotNet $DotNet
    (@($result.Trace | Where-Object Kind -eq 'Import').Name -join ',') | Should -Be ($requiredModules -join ',')
    if ($Mode -eq 'true') {
      $result.ExitCode | Should -Be 0 -Because $result.Error
      @($result.Trace | Where-Object Kind -eq 'Forbidden').Count | Should -Be 0
      $receipts = @($result.Output | Where-Object { $_ -match '^\{' } | ForEach-Object { $_ | ConvertFrom-Json })
      $receipts.Count | Should -Be 1
      $receipts[0].PowerShellVersion | Should -BeExactly $Version
      $receipts[0].DotNetVersion | Should -BeExactly $DotNet
    }
    else {
      $result.ExitCode | Should -Be 1
      $result.Error | Should -Be 'FORBIDDEN_DOWNSTREAM:Connect-AzAccount'
      (@($result.Trace | Where-Object Kind -eq 'Forbidden').Name -join ',') | Should -Be 'Connect-AzAccount'
      Assert-NoValidationReceipt $result
    }
  }

  It 'rejects unsupported host <Version> <Edition> .NET <DotNet> before all work in <Mode> mode, preview flag <PreviewMode>' -ForEach @(
    foreach ($hostCase in @(
      @{ Version = '7.5.99'; Edition = 'Core'; DotNet = '10.0.9' },
      @{ Version = '7.6.0-preview.4'; Edition = 'Core'; DotNet = '10.0.9' },
      @{ Version = '7.6.0-preview.6'; Edition = 'Core'; DotNet = '10.0.9' },
      @{ Version = '7.6.0-rc.1'; Edition = 'Core'; DotNet = '10.0.9' },
      @{ Version = '7.7.0-preview.1'; Edition = 'Core'; DotNet = '10.0.9' },
      @{ Version = '8.0.0-preview.1'; Edition = 'Core'; DotNet = '11.0.0' },
      @{ Version = '7.6.0-Preview.5'; Edition = 'Core'; DotNet = '10.0.9' },
      @{ Version = '7.6.0-preview.5+provider.1'; Edition = 'Core'; DotNet = '10.0.9' },
      @{ Version = '7.6.0-preview.5'; Edition = 'Desktop'; DotNet = '10.0.9' },
      @{ Version = '7.6.0-preview.5'; Edition = 'Core'; DotNet = '9.0.10' },
      @{ Version = '7.6.0-preview.5'; Edition = 'Core'; DotNet = '11.0.0' },
      @{ Version = '7.6.0'; Edition = 'Desktop'; DotNet = '10.0.9' },
      @{ Version = '7.6.0'; Edition = 'Core'; DotNet = '9.0.10' }
    )) {
      foreach ($mode in 'omitted', 'false', 'true', 'legacy-preview') {
        @{ Version = $hostCase.Version; Edition = $hostCase.Edition; DotNet = $hostCase.DotNet
           Mode = $(if ($mode -eq 'legacy-preview') { 'true' } else { $mode })
           PreviewMode = $(if ($mode -eq 'legacy-preview') { 'true' } else { 'default' }) }
      }
    }
  ) {
    $result = Invoke-OfflineRunbook -Mode $Mode -RuntimeVersion $Version -RuntimeEdition $Edition -RuntimeDotNet $DotNet -PreviewMode $PreviewMode
    $result.ExitCode | Should -Be 1
    $result.Error | Should -Be ('The maintained runbook requires PowerShell 7.6+ Core on .NET 10+ (stable releases, or exactly 7.6.0-preview.5 on .NET 10). Observed PowerShell={0}; PSEdition={1}; EnvironmentVersion={2}; EnvironmentVersionMajor={3}.' -f $Version, $Edition, $DotNet, ([version]$DotNet).Major)
    @($result.Trace).Count | Should -Be 0
    @($result.Output).Count | Should -Be 0
    Assert-NoValidationReceipt $result
  }

  It 'retains the legacy preview flag runtime-only constraint in <Mode> mode' -ForEach @(
    @{ Mode = 'omitted' }, @{ Mode = 'false' }
  ) {
    $result = Invoke-OfflineRunbook -Mode $Mode -RuntimeVersion '7.6.0-preview.5' -RuntimeEdition 'Core' -RuntimeDotNet '10.0.9' -PreviewMode 'true'
    $result.ExitCode | Should -Be 1
    $result.Error | Should -Be 'AllowRuntimeValidationPreview requires RuntimeValidationOnly.'
    @($result.Trace).Count | Should -Be 0
    @($result.Output).Count | Should -Be 0
  }
}
