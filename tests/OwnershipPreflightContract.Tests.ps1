Describe 'Automation owns its resource group before native azd initialization' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $preup = Get-Content (Join-Path $root 'scripts/Run-AzdPreUp.ps1') -Raw
    $preprovision = Get-Content (Join-Path $root 'scripts/Run-AzdPreProvision.ps1') -Raw
    $yaml = Get-Content (Join-Path $root 'azure.yaml') -Raw
  }
  It 'passes the exact project, environment and solution to canonical preup' {
    $preup | Should -Match 'Invoke-MaesterPreUp -ProjectRoot \(Split-Path \$PSScriptRoot -Parent\)'
    $preup | Should -Match '-EnvironmentName \$env:AZURE_ENV_NAME -SolutionName ''automation-account'''
  }
  It 'revalidates through canonical preprovision without a late duplicate initializer' {
    $preprovision | Should -Match '-ProjectRoot \(Split-Path \$PSScriptRoot -Parent\) -EnvironmentName \$EnvironmentName'
    $preprovision | Should -Not -Match 'Initialize-MaesterInfrastructureOwnership'
  }
  It 'retains project-level hooks and explicit separate postprovision consent' {
    $yaml | Should -Match '(?s)hooks:.*preup:.*Run-AzdPreUp.ps1.*preprovision:.*Run-AzdPreProvision.ps1'
    $yaml | Should -Match 'Run-AzdPostProvision.ps1 -InteractiveConsent'
  }
}
