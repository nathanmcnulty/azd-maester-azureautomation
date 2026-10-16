# All checks are local. These tests do not deploy resources or call Azure APIs.
BeforeAll {
  . (Join-Path $PSScriptRoot '../scripts/Resolve-AutomationStorageTarget.ps1')
  $script:storageTargetArguments = @{
    SubscriptionId = '11111111-1111-4111-8111-111111111111'
    ResourceGroupName = 'rg-maester-test'; EnvironmentName = 'maester-test'
  }
  $script:storageGolden = 'stmaestervip3dkg72ognq'
  $script:webGolden = 'app-maester-vip3dkg72ognq'
  try { $script:realStorageBicep = Get-MaesterStorageTargetBicepExecutable } catch { $script:realStorageBicep = $null }

  function New-StorageTargetCompilerOutput {
    param($StorageName = $script:storageGolden, $WebName = $script:webGolden)
    $parameterFile = @{
      '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
      contentVersion = '1.0.0.0'
      parameters = @{ storageAccountName = @{ value = $StorageName }; webAppName = @{ value = $WebName } }
    }
    @{ parametersJson = ($parameterFile | ConvertTo-Json -Depth 5 -Compress); templateJson = $null; templateSpecId = $null } |
      ConvertTo-Json -Depth 5 -Compress
  }

  function Get-StorageTestNames {
    param([hashtable]$Overrides = @{})
    $arguments = $script:storageTargetArguments.Clone()
    foreach ($key in $Overrides.Keys) { $arguments[$key] = $Overrides[$key] }
    Get-MaesterDeterministicDeploymentNames @arguments
  }

  function Assert-StorageTestTarget {
    param([hashtable]$Values)
    Assert-MaesterDeterministicStorageTarget @script:storageTargetArguments -EnvironmentValues $Values
  }
}

Describe 'Deterministic infrastructure target binding' {
  BeforeEach {
    Mock Get-MaesterStorageTargetBicepExecutable { 'existing-bicep' }
    Mock Invoke-MaesterStorageTargetBicep { New-StorageTargetCompilerOutput }
  }

  It 'accepts the exact deterministic storage output' {
    { Assert-StorageTestTarget -Values @{ STORAGE_ACCOUNT_NAME = $script:storageGolden; WEB_APP_ENABLED = 'false' } } | Should -Not -Throw
    (Get-StorageTestNames).StorageAccountName | Should -BeExactly $script:storageGolden
  }

  It 'rejects a plausible different storage account even if an external runtime variable names it' {
    { Assert-StorageTestTarget -Values @{
        STORAGE_ACCOUNT_NAME = 'stmaesterotheraccount'; WEB_APP_ENABLED = 'false'
        runtimevariableStorageAccountName = 'stmaesterotheraccount'
      } } | Should -Throw '*STORAGE_ACCOUNT_NAME*deterministic*'
  }

  It 'leaves the external runtime data sink untouched' {
    $values = @{ STORAGE_ACCOUNT_NAME = $script:storageGolden; WEB_APP_ENABLED = 'false'; runtimevariableStorageAccountName = 'externalreports123' }
    $before = $values | ConvertTo-Json -Compress
    Assert-StorageTestTarget -Values $values
    ($values | ConvertTo-Json -Compress) | Should -BeExactly $before
  }

  It 'rejects missing, non-string, uppercase, and malformed storage outputs before compiling' {
    foreach ($invalidName in @($null, '', '   ', 'STMAESTERVIP3DKG72OGNQ', 'stmaester/path', @('stmaestervip3dkg72ognq'))) {
      { Assert-StorageTestTarget -Values @{ STORAGE_ACCOUNT_NAME = $invalidName } } | Should -Throw '*STORAGE_ACCOUNT_NAME*'
    }
    Should -Invoke Invoke-MaesterStorageTargetBicep -Times 0 -Exactly
  }

  It 'requires an exact deterministic Web App only when enabled' {
    { Assert-StorageTestTarget -Values @{ STORAGE_ACCOUNT_NAME = $script:storageGolden; WEB_APP_ENABLED = 'true'; WEB_APP_NAME = $script:webGolden } } | Should -Not -Throw
    foreach ($invalidName in @($null, '', 'app-maester-another', $script:webGolden.ToUpperInvariant(), @($script:webGolden))) {
      { Assert-StorageTestTarget -Values @{ STORAGE_ACCOUNT_NAME = $script:storageGolden; WEB_APP_ENABLED = 'true'; WEB_APP_NAME = $invalidName } } | Should -Throw '*WEB_APP_NAME*deterministic*'
    }
    { Assert-StorageTestTarget -Values @{ STORAGE_ACCOUNT_NAME = $script:storageGolden; WEB_APP_ENABLED = 'false'; WEB_APP_NAME = 'unrelated' } } | Should -Not -Throw
  }

  It 'preserves the exact verified ARM resource group ID and environment casing' {
    Get-StorageTestNames -Overrides @{
      ResourceGroupId = '/SUBSCRIPTIONS/11111111-1111-4111-8111-111111111111/RESOURCEGROUPS/RG-Maester-Test'
      EnvironmentName = 'Maester-Test'
    } | Out-Null
    Should -Invoke Invoke-MaesterStorageTargetBicep -Times 1 -Exactly -ParameterFilter {
      $ResourceGroupId -ceq '/SUBSCRIPTIONS/11111111-1111-4111-8111-111111111111/RESOURCEGROUPS/RG-Maester-Test' -and
      $EnvironmentName -ceq 'Maester-Test'
    }
  }

  It 'rejects a different or malformed ARM resource group ID before compiling' {
    foreach ($id in @('/subscriptions/other/resourceGroups/rg-maester-test',
        '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/other',
        '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-maester-test/providers/extra',
        "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-maester-test`n")) {
      { Get-StorageTestNames -Overrides @{ ResourceGroupId = $id } } | Should -Throw '*resource group ID*'
    }
    Should -Invoke Invoke-MaesterStorageTargetBicep -Times 0 -Exactly
  }

  It 'rejects unsafe or malformed input without constructing compiler source from it' {
    foreach ($overrides in @(
        @{ SubscriptionId = 'sub/other' }, @{ SubscriptionId = "sub`n" }, @{ SubscriptionId = ('a' * 65) },
        @{ ResourceGroupName = 'rg/other' }, @{ ResourceGroupName = 'rg.' }, @{ ResourceGroupName = ('a' * 91) },
        @{ ResourceGroupName = 'rg''${bad}' }, @{ EnvironmentName = "test'" },
        @{ EnvironmentName = "dev`nparam storageAccountName = 'injected'" }, @{ EnvironmentName = ('a' * 65) })) {
      { Get-StorageTestNames -Overrides $overrides } | Should -Throw '*required to compute*'
    }
    Should -Invoke Invoke-MaesterStorageTargetBicep -Times 0 -Exactly
  }

  It 'fails closed when the installed compiler cannot run or rejects the file' {
    Mock Invoke-MaesterStorageTargetBicep { throw 'Bicep compiler failed.' }
    { Get-StorageTestNames } | Should -Throw '*compiler failed*'
  }

  It 'rejects malformed or unexpected compiler stdout' {
    foreach ($badOutput in @('', 'not JSON', '{}', '[]', 'null', '{"parametersJson":null,"templateJson":null,"templateSpecId":null}',
        '{"parametersJson":"{}","templateJson":null,"templateSpecId":null}',
        '{"parametersJson":"{}","templateJson":{},"templateSpecId":null}',
        ((New-StorageTargetCompilerOutput) + '{}'))) {
      $script:badStorageCompilerOutput = $badOutput
      Mock Invoke-MaesterStorageTargetBicep { $script:badStorageCompilerOutput }
      { Get-StorageTestNames } | Should -Throw '*invalid deterministic storage target*'
    }
  }

  It 'rejects invalid target types, prefixes, suffix lengths, case, and inconsistent Web App names' {
    foreach ($case in @(
        @{ StorageName = $null }, @{ StorageName = @('stmaestervip3dkg72ognq') },
        @{ StorageName = 'stother12' }, @{ StorageName = 'stmaester123' },
        @{ StorageName = $script:storageGolden.ToUpperInvariant() },
        @{ WebName = 'app-maester-another' }, @{ WebName = $null }, @{ WebName = @($script:webGolden) })) {
      $script:badStorageCompilerOutput = New-StorageTargetCompilerOutput @case
      Mock Invoke-MaesterStorageTargetBicep { $script:badStorageCompilerOutput }
      { Get-StorageTestNames } | Should -Throw '*invalid deterministic storage target*'
    }
  }

  It 'requires the target value fields while allowing unrelated compiler metadata' {
    $compiled = New-StorageTargetCompilerOutput | ConvertFrom-Json -AsHashtable
    $parametersFile = $compiled.parametersJson | ConvertFrom-Json -AsHashtable
    $parametersFile.parameters.extra = @{ value = 'unrelated compiler metadata' }
    $compiled.parametersJson = $parametersFile | ConvertTo-Json -Depth 5 -Compress
    $compiled.extra = 'ignored'
    $script:storageCompilerOutput = $compiled | ConvertTo-Json -Compress
    Mock Invoke-MaesterStorageTargetBicep { $script:storageCompilerOutput }
    (Get-StorageTestNames).StorageAccountName | Should -BeExactly $script:storageGolden
    $parametersFile.parameters.storageAccountName.Remove('value')
    $compiled.parametersJson = $parametersFile | ConvertTo-Json -Depth 5 -Compress
    $script:storageCompilerOutput = $compiled | ConvertTo-Json -Compress
    { Get-StorageTestNames } | Should -Throw '*invalid deterministic storage target*'
  }

}

Describe 'Existing local Bicep executable resolution' {
  BeforeEach {
    $script:savedStorageBicepExe = $env:BICEP_EXE
    $script:savedStorageAzureConfig = $env:AZURE_CONFIG_DIR
    $env:BICEP_EXE = $null
    $env:AZURE_CONFIG_DIR = Join-Path $TestDrive "azure-$([guid]::NewGuid().ToString('N'))"
  }
  AfterEach {
    $env:BICEP_EXE = $script:savedStorageBicepExe
    $env:AZURE_CONFIG_DIR = $script:savedStorageAzureConfig
  }

  It 'prefers an explicit existing executable without command-string evaluation' {
    $file = Join-Path $TestDrive 'bicep with spaces'
    Set-Content -LiteralPath $file -Value 'test fixture'
    $env:BICEP_EXE = $file
    Mock Get-Command { throw 'PATH lookup must not run.' }
    Get-MaesterStorageTargetBicepExecutable | Should -BeExactly $file
  }

  It 'fails closed for an explicitly configured missing executable' {
    $env:BICEP_EXE = Join-Path $TestDrive 'absent-bicep'
    Mock Get-Command { throw 'Must not fall back after a bad explicit path.' }
    { Get-MaesterStorageTargetBicepExecutable } | Should -Throw '*BICEP_EXE*existing*'
    $env:BICEP_EXE = '  '
    { Get-MaesterStorageTargetBicepExecutable } | Should -Throw '*BICEP_EXE*existing*'
  }

  It 'selects only an application from PATH' {
    Mock Get-Command { [pscustomobject]@{ Source = '/existing/path/bicep' } } -ParameterFilter { $Name -eq 'bicep' -and $CommandType -eq 'Application' }
    Get-MaesterStorageTargetBicepExecutable | Should -BeExactly '/existing/path/bicep'
    Should -Invoke Get-Command -Times 1 -Exactly -ParameterFilter { $CommandType -eq 'Application' }
  }

  It 'uses the already installed Azure CLI binary without invoking az' {
    Mock Get-Command { $null }
    $binary = Join-Path $env:AZURE_CONFIG_DIR $(if ($IsWindows) { 'bin/bicep.exe' } else { 'bin/bicep' })
    New-Item -ItemType Directory -Path (Split-Path -Parent $binary) -Force | Out-Null
    Set-Content -LiteralPath $binary -Value 'test fixture'
    Get-MaesterStorageTargetBicepExecutable | Should -BeExactly $binary
  }

  It 'fails closed without installing or invoking Azure CLI when no binary exists' {
    Mock Get-Command { $null }
    { Get-MaesterStorageTargetBicepExecutable } | Should -Throw '*existing Bicep CLI*required*'
  }
}

Describe 'Local compiler process failures' {
  BeforeEach {
    $script:compilerFailureTempRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:compilerFailureTempRoot | Out-Null
    # Observe only this invocation's directory; other test processes may also
    # be evaluating Bicep concurrently in the system temporary directory.
    Mock Join-Path {
      if ($ChildPath -like 'maester-storage-target-*') {
        [IO.Path]::Combine($script:compilerFailureTempRoot, $ChildPath)
      }
      else { [IO.Path]::Combine($Path, $ChildPath) }
    }
  }

  It 'throws if an executable is absent and removes temporary files' {
    { Invoke-MaesterStorageTargetBicep -Executable (Join-Path $TestDrive 'missing-executable') -ResourceGroupId '/subscriptions/sub-test/resourceGroups/rg-test' -EnvironmentName test } | Should -Throw
    Should -Invoke Join-Path -Times 1 -Exactly -ParameterFilter { $ChildPath -like 'maester-storage-target-*' }
    @(Get-ChildItem -LiteralPath $script:compilerFailureTempRoot).Count | Should -Be 0
  }

  It 'rejects nonzero exit and compiler diagnostics, then removes temporary files' {
    $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $originalOptOut = $env:POWERSHELL_TELEMETRY_OPTOUT
    $originalUpdateCheck = $env:POWERSHELL_UPDATECHECK
    try {
      $env:POWERSHELL_TELEMETRY_OPTOUT = 'parent-value-must-remain'
      $env:POWERSHELL_UPDATECHECK = 'parent-value-must-remain'
      { Invoke-MaesterStorageTargetBicep -Executable $pwsh -ResourceGroupId '/subscriptions/sub-test/resourceGroups/rg-test' -EnvironmentName test } | Should -Throw '*Bicep CLI failed*'
      $env:POWERSHELL_TELEMETRY_OPTOUT | Should -BeExactly 'parent-value-must-remain'
      $env:POWERSHELL_UPDATECHECK | Should -BeExactly 'parent-value-must-remain'
    }
    finally {
      $env:POWERSHELL_TELEMETRY_OPTOUT = $originalOptOut
      $env:POWERSHELL_UPDATECHECK = $originalUpdateCheck
    }
    Should -Invoke Join-Path -Times 1 -Exactly -ParameterFilter { $ChildPath -like 'maester-storage-target-*' }
    @(Get-ChildItem -LiteralPath $script:compilerFailureTempRoot).Count | Should -Be 0
  }

  It 'sets the official PowerShell telemetry opt-out only on the child process' {
    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../scripts/Resolve-AutomationStorageTarget.ps1') -Raw
    $source | Should -Match '\$start\.Environment\[''POWERSHELL_TELEMETRY_OPTOUT''\]\s*=\s*''1'''
    $source | Should -Match '\$start\.Environment\[''POWERSHELL_UPDATECHECK''\]\s*=\s*''Off'''
    $source | Should -Not -Match '\$env:POWERSHELL_TELEMETRY_OPTOUT\s*='
    $source | Should -Not -Match '\$env:POWERSHELL_UPDATECHECK\s*='
  }
}

Describe 'Actual Bicep evaluation parity' {
  BeforeAll {
    $script:savedGoldenBicepExe = $env:BICEP_EXE
    if ($script:realStorageBicep) { $env:BICEP_EXE = $script:realStorageBicep }
  }
  AfterAll { $env:BICEP_EXE = $script:savedGoldenBicepExe }

  It 'keeps the evaluator expression aligned with main.bicep naming expressions' {
    $main = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../infra/main.bicep') -Raw
    $main | Should -Match "(?m)^var resourceSuffix = toLower\(uniqueString\(resourceGroup\(\)\.id, environmentName\)\)\s*$"
    $main | Should -Match '(?m)^var storageAccountName = ''stmaester\$\{resourceSuffix\}''\s*$'
    $main | Should -Match '(?m)^var webAppName = ''app-maester-\$\{resourceSuffix\}''\s*$'
  }

  It 'matches local Bicep golden names across subscriptions, RG casing, environment casing, and allowed punctuation' {
    if (-not $script:realStorageBicep) { Set-ItResult -Skipped -Because 'An existing Bicep CLI is unavailable.'; return }
    $cases = @(
      @{ SubscriptionId = '11111111-1111-4111-8111-111111111111'; ResourceGroupName = 'rg-maester-test'; EnvironmentName = 'maester-test'; Expected = 'vip3dkg72ognq' },
      @{ SubscriptionId = '11111111-1111-4111-8111-111111111111'; ResourceGroupName = 'RG-Maester-Test'; EnvironmentName = 'maester-test'; Expected = 'aec6c3qydrpho' },
      @{ SubscriptionId = '11111111-1111-4111-8111-111111111111'; ResourceGroupName = 'rg-maester-test'; EnvironmentName = 'Maester-Test'; Expected = '6jmuc6pbpqjau' },
      @{ SubscriptionId = '22222222-2222-4222-8222-222222222222'; ResourceGroupName = 'rg-prod'; EnvironmentName = 'prod'; Expected = 'pywxhqjsvz3po' },
      @{ SubscriptionId = '11111111-1111-4111-8111-111111111111'; ResourceGroupName = 'rg_Équipe(1)'; EnvironmentName = 'Prod_(1).Blue'; Expected = 'ql7sqarxrlpn2' }
    )
    foreach ($case in $cases) {
      $expected = $case.Expected
      $arguments = $case.Clone(); $arguments.Remove('Expected')
      $names = Get-MaesterDeterministicDeploymentNames @arguments
      $names.StorageAccountName | Should -BeExactly "stmaester$expected"
      $names.WebAppName | Should -BeExactly "app-maester-$expected"
    }
  }

  It 'uses the verified ARM resource group casing instead of the selected spelling' {
    if (-not $script:realStorageBicep) { Set-ItResult -Skipped -Because 'An existing Bicep CLI is unavailable.'; return }
    $names = Get-StorageTestNames -Overrides @{ ResourceGroupId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/RG-Maester-Test' }
    $names.StorageAccountName | Should -BeExactly 'stmaesteraec6c3qydrpho'
  }

  It 'blocks inherited parameter overrides and leaves caller variables unchanged' {
    if (-not $script:realStorageBicep) { Set-ItResult -Skipped -Because 'An existing Bicep CLI is unavailable.'; return }
    $names = @('BICEP_PARAMETERS_OVERRIDES', 'MAESTER_STORAGE_RESOURCE_GROUP_ID', 'MAESTER_STORAGE_ENVIRONMENT_NAME')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
      $env:BICEP_PARAMETERS_OVERRIDES = '{"storageAccountName":"stmaesterxxxxxxxxxxxxx","webAppName":"app-maester-xxxxxxxxxxxxx"}'
      $env:MAESTER_STORAGE_RESOURCE_GROUP_ID = 'unrelated parent group'
      $env:MAESTER_STORAGE_ENVIRONMENT_NAME = 'unrelated parent environment'
      (Get-StorageTestNames).StorageAccountName | Should -BeExactly $script:storageGolden
      $env:BICEP_PARAMETERS_OVERRIDES | Should -BeExactly '{"storageAccountName":"stmaesterxxxxxxxxxxxxx","webAppName":"app-maester-xxxxxxxxxxxxx"}'
      $env:MAESTER_STORAGE_RESOURCE_GROUP_ID | Should -BeExactly 'unrelated parent group'
      $env:MAESTER_STORAGE_ENVIRONMENT_NAME | Should -BeExactly 'unrelated parent environment'
    }
    finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
  }
}
