#Requires -Version 7.6
function Get-MaesterStorageTargetBicepExecutable {
  [CmdletBinding()]
  param()

  # Invoke an already installed binary directly. `az bicep` may auto-install or
  # check remote versions, neither of which belongs in this local preflight.
  if ($env:BICEP_EXE) {
    if ([string]::IsNullOrWhiteSpace($env:BICEP_EXE) -or -not (Test-Path -LiteralPath $env:BICEP_EXE -PathType Leaf)) {
      throw 'BICEP_EXE must identify an existing Bicep CLI executable.'
    }
    return (Get-Item -LiteralPath $env:BICEP_EXE -ErrorAction Stop).FullName
  }
  $command = Get-Command bicep -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command) { return $command.Source }

  # This is the installation directory used by Azure CLI, including its
  # supported AZURE_CONFIG_DIR override.
  $azureConfigDir = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
  $binaryName = if ($IsWindows) { 'bicep.exe' } else { 'bicep' }
  $installedBinary = Join-Path $azureConfigDir "bin/$binaryName"
  if (Test-Path -LiteralPath $installedBinary -PathType Leaf) {
    return (Get-Item -LiteralPath $installedBinary -ErrorAction Stop).FullName
  }
  throw 'An existing Bicep CLI supporting using none (v0.31.0 or newer) is required to verify the deterministic storage target. Set BICEP_EXE or make bicep available on PATH.'
}

function Invoke-MaesterStorageTargetBicep {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$ResourceGroupId,
    [Parameter(Mandatory)][string]$EnvironmentName
  )

  $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) "maester-storage-target-$([guid]::NewGuid().ToString('N'))"
  $process = $null
  try {
    [IO.Directory]::CreateDirectory($tempDirectory) | Out-Null
    $parameterFile = Join-Path $tempDirectory 'storage.bicepparam'
    # Keep input out of Bicep source and shell command strings. This expression
    # mirrors infra/main.bicep; Bicep itself evaluates uniqueString locally.
    $source = @'
using none
var resourceSuffix = toLower(uniqueString(readEnvironmentVariable('MAESTER_STORAGE_RESOURCE_GROUP_ID'), readEnvironmentVariable('MAESTER_STORAGE_ENVIRONMENT_NAME')))
param storageAccountName = 'stmaester${resourceSuffix}'
param webAppName = 'app-maester-${resourceSuffix}'
'@
    [IO.File]::WriteAllText($parameterFile, $source, [Text.UTF8Encoding]::new($false))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $tempDirectory
    foreach ($argument in @('build-params', $parameterFile, '--stdout', '--no-restore')) {
      $start.ArgumentList.Add($argument)
    }
    $start.Environment['MAESTER_STORAGE_RESOURCE_GROUP_ID'] = $ResourceGroupId
    $start.Environment['MAESTER_STORAGE_ENVIRONMENT_NAME'] = $EnvironmentName
    # PowerShell-based executable wrappers must not send startup telemetry.
    # PowerShell reads this official opt-out before initializing telemetry.
    $start.Environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
    $start.Environment['POWERSHELL_UPDATECHECK'] = 'Off'
    # build-params otherwise applies this inherited variable over the expression.
    # Child-only environment changes leave all caller variables untouched.
    $start.Environment.Remove('BICEP_PARAMETERS_OVERRIDES') | Out-Null
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'The local Bicep CLI did not start.' }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
      $process.Kill($true)
      throw 'The local Bicep storage target evaluation timed out.'
    }
    $output = $stdout.GetAwaiter().GetResult()
    $diagnostics = $stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($diagnostics)) {
      throw 'The local Bicep CLI failed to evaluate the deterministic storage target without diagnostics.'
    }
    return $output
  }
  finally {
    if ($process) { $process.Dispose() }
    if (Test-Path -LiteralPath $tempDirectory) {
      Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction Stop
    }
  }
}

function Get-MaesterDeterministicDeploymentNames {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$EnvironmentName,
    [string]$ResourceGroupId = ''
  )

  if ($SubscriptionId -cnotmatch '\A[a-zA-Z0-9\-]{1,64}\z') {
    throw 'A valid subscription identifier is required to compute the deterministic storage target.'
  }
  if ($ResourceGroupName -cnotmatch '\A[\p{L}\p{Nd}_.()\-]{1,90}\z' -or $ResourceGroupName.EndsWith('.')) {
    throw 'A valid resource group name is required to compute the deterministic storage target.'
  }
  # Match azd environment naming rules without changing the case used by ARM.
  if ($EnvironmentName -cnotmatch '\A[a-zA-Z0-9_.()\-]{1,64}\z') {
    throw 'A valid azd environment name is required to compute the deterministic storage target.'
  }

  $expectedGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
  if ($ResourceGroupId -and $ResourceGroupId -ine $expectedGroupId) {
    throw 'The resource group ID does not match the selected subscription and resource group.'
  }
  # ARM may return different casing from the selected azd spelling. Hash its
  # verified exact ID when supplied, as resourceGroup().id does in main.bicep.
  if (-not $ResourceGroupId) { $ResourceGroupId = $expectedGroupId }
  $executable = Get-MaesterStorageTargetBicepExecutable
  $output = Invoke-MaesterStorageTargetBicep -Executable $executable -ResourceGroupId $resourceGroupId -EnvironmentName $EnvironmentName
  try {
    $compiled = $output | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($compiled.parametersJson -isnot [string]) { throw 'Missing compiler parameters.' }
    $parameters = ($compiled.parametersJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop).parameters
    $storageName = $parameters.storageAccountName.value
    $webName = $parameters.webAppName.value
    if ($storageName -isnot [string] -or $webName -isnot [string] -or
        $storageName -cnotmatch '\Astmaester[a-z0-9]{13}\z' -or
        $webName -cne "app-maester-$($storageName.Substring(9))") {
      throw 'Invalid deterministic target names.'
    }
    return [pscustomobject]@{ StorageAccountName = $storageName; WebAppName = $webName }
  }
  catch { throw 'The local Bicep CLI returned an invalid deterministic storage target.' }
}

function Assert-MaesterDeterministicStorageTarget {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentValues,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$EnvironmentName,
    [string]$ResourceGroupId = ''
  )

  $storageName = $EnvironmentValues['STORAGE_ACCOUNT_NAME']
  if ($storageName -isnot [string] -or $storageName -cnotmatch '\A[a-z0-9]{3,24}\z') {
    throw 'Deployment output STORAGE_ACCOUNT_NAME is missing or invalid.'
  }
  $expected = Get-MaesterDeterministicDeploymentNames -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -EnvironmentName $EnvironmentName -ResourceGroupId $ResourceGroupId
  if ($storageName -cne $expected.StorageAccountName) {
    throw "STORAGE_ACCOUNT_NAME does not match the deterministic main.bicep storage target '$($expected.StorageAccountName)'."
  }
  if ([string]$EnvironmentValues['WEB_APP_ENABLED'] -ieq 'true' -and
      ($EnvironmentValues['WEB_APP_NAME'] -isnot [string] -or $EnvironmentValues['WEB_APP_NAME'] -cne $expected.WebAppName)) {
    throw "WEB_APP_NAME does not match the deterministic main.bicep Web App target '$($expected.WebAppName)'."
  }
  # runtimevariableStorageAccountName is an externally configurable data sink;
  # it neither establishes ownership nor changes this deployment target.
}
