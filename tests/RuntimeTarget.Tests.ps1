Describe 'Explicit Automation runtime target selection' {
BeforeAll {
  . (Join-Path $PSScriptRoot '../scripts/PreservationMetadata.ps1')
  $script:priorRuntimeTarget = [Environment]::GetEnvironmentVariable('AUTOMATION_RUNTIME_ENVIRONMENT_NAME')
}
BeforeEach { $env:AUTOMATION_RUNTIME_ENVIRONMENT_NAME = $null }
AfterAll { $env:AUTOMATION_RUNTIME_ENVIRONMENT_NAME = $script:priorRuntimeTarget }

  It 'retains the default for an absent or empty setting' {
    Resolve-MaesterRuntimeEnvironmentName -EnvironmentValues @{} | Should -BeExactly 'PowerShell-76-Maester'
    Resolve-MaesterRuntimeEnvironmentName -EnvironmentValues @{AUTOMATION_RUNTIME_ENVIRONMENT_NAME=''} | Should -BeExactly 'PowerShell-76-Maester'
  }
  It 'uses the selected target and accepts matching process selection' {
    $env:AUTOMATION_RUNTIME_ENVIRONMENT_NAME = 'PowerShell-76-Maester-230'
    Resolve-MaesterRuntimeEnvironmentName -EnvironmentValues @{AUTOMATION_RUNTIME_ENVIRONMENT_NAME='PowerShell-76-Maester-230'} | Should -BeExactly 'PowerShell-76-Maester-230'
  }
  It 'refuses a process-only target when the selected environment omits it' {
    $env:AUTOMATION_RUNTIME_ENVIRONMENT_NAME = 'PowerShell-76-Maester-230'
    { Resolve-MaesterRuntimeEnvironmentName -EnvironmentValues @{} } | Should -Throw '*process-only targets are not accepted*'
  }
  It 'refuses a conflicting process selection' {
    $env:AUTOMATION_RUNTIME_ENVIRONMENT_NAME = 'PowerShell-76-Maester-230'
    { Resolve-MaesterRuntimeEnvironmentName -EnvironmentValues @{AUTOMATION_RUNTIME_ENVIRONMENT_NAME='PowerShell-76-Maester'} } | Should -Throw '*differs from the selected azd environment*'
  }
  It 'rejects a nonstring selection' {
    { Resolve-MaesterRuntimeEnvironmentName -EnvironmentValues @{AUTOMATION_RUNTIME_ENVIRONMENT_NAME=42} } | Should -Throw '*must be a string*'
  }
  It 'rejects invalid name <Value>' -ForEach @(
    @{Value=' '}, @{Value='../runtime'}, @{Value='runtime/child'}, @{Value='2runtime'}, @{Value='runtime?x=y'}, @{Value="runtime`nother"}, @{Value="runtime`n"}
  ) {
    { Resolve-MaesterRuntimeEnvironmentName -EnvironmentValues @{AUTOMATION_RUNTIME_ENVIRONMENT_NAME=$Value} } | Should -Throw '*must start with a letter*'
  }
}
