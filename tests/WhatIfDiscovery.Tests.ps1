BeforeAll {
  $runbook=Join-Path $PSScriptRoot '../scripts/Invoke-MaesterAutomationRunbook.ps1'
  $tokens=$null;$parseErrors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($runbook,[ref]$tokens,[ref]$parseErrors)
  $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Repair-MaesterWhatIfDiscovery'},$true)
  . ([scriptblock]::Create($definition.Extent.Text))
  $fixture=Join-Path $PSScriptRoot 'fixtures/maester-230/WhatIfDiscovery.ps1'
  $harness=Join-Path $PSScriptRoot 'fixtures/Invoke-WhatIfDiscovery.ps1'
  function New-WhatIfFixture {
    $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $dir=Join-Path $root 'Maester/Entra';New-Item -ItemType Directory -Path $dir -Force|Out-Null
    $target=Join-Path $dir 'Test-ConditionalAccessWhatIf.Tests.ps1';Copy-Item $fixture $target
    @{root=$root;target=$target}
  }
  function Invoke-WhatIfFixture {
    param($Fixture,[int]$Members,[int]$Emergency,[switch]$FilterMemberToOne)
    $output=Join-Path $Fixture.root 'result.json'
    & (Get-Process -Id $PID).Path -NoProfile -File $harness -TestPath $Fixture.target -ResultPath $output -MemberCount $Members -EmergencyCount $Emergency -FilterMemberToOne:$FilterMemberToOne *> (Join-Path $Fixture.root 'child.log')
    $LASTEXITCODE|Should -Be 0
    Get-Content $output -Raw|ConvertFrom-Json
  }
}
Describe 'Locked Maester What-If collection compatibility' {
  It 'reproduces the actual scalar emergency-user discovery error before repair' {
    $f=New-WhatIfFixture;$result=Invoke-WhatIfFixture $f -Members 2 -Emergency 1
    ($result.containerErrors+$result.blockErrors)|Should -BeGreaterThan 0
  }
  It 'retains all tests and calls for singleton and multiple collections' -ForEach @(
    @{Members=2;Emergency=1;Filter=$false;Expected=3},
    @{Members=1;Emergency=2;Filter=$false;Expected=3},
    @{Members=2;Emergency=2;Filter=$false;Expected=4},
    @{Members=2;Emergency=1;Filter=$true;Expected=2},
    @{Members=0;Emergency=0;Filter=$false;Expected=0}
  ) {
    $f=New-WhatIfFixture;Repair-MaesterWhatIfDiscovery -TestsPath $f.root|Out-Null
    $result=Invoke-WhatIfFixture $f -Members $Members -Emergency $Emergency -FilterMemberToOne:$Filter
    $result.failed|Should -Be 0;($result.containerErrors+$result.blockErrors)|Should -Be 0
    $result.passed|Should -Be $Expected;@($result.calls).Count|Should -Be $Expected
    @($result.calls|Where-Object {-not $_.userId}).Count|Should -Be 0
    @($result.calls|Where-Object operation -eq emergency).Count|Should -Be $Emergency
    if ($Expected -eq 0) { $result.total|Should -Be 0 }
  }
  It 'keeps existing multi-user test identities and request arguments' {
    $original=New-WhatIfFixture;$patched=New-WhatIfFixture
    Repair-MaesterWhatIfDiscovery -TestsPath $patched.root|Out-Null
    $a=Invoke-WhatIfFixture $original -Members 2 -Emergency 2
    $b=Invoke-WhatIfFixture $patched -Members 2 -Emergency 2
    $b.names|Should -Be $a.names
    ($b.calls|Select-Object operation,userId,application,client|ConvertTo-Json -Depth 6 -Compress)|Should -BeExactly ($a.calls|Select-Object operation,userId,application,client|ConvertTo-Json -Depth 6 -Compress)
  }
  It 'recognizes its exact repair and is idempotent' {
    $f=New-WhatIfFixture;$first=Repair-MaesterWhatIfDiscovery -TestsPath $f.root
    $before=(Get-FileHash $f.target).Hash;$second=Repair-MaesterWhatIfDiscovery -TestsPath $f.root
    $first.Changed|Should -BeTrue;$second.Changed|Should -BeFalse
    (Get-FileHash $f.target).Hash|Should -BeExactly $before
    $second.EffectiveSha256|Should -BeExactly '957AC886DF9FFFBEB75BA5F27CE0735057142F8BEDEA383D80FFE4858D138939'
  }
  It 'rejects unknown upstream content without rewriting it' {
    $f=New-WhatIfFixture;Add-Content $f.target '# changed upstream'
    $before=(Get-FileHash $f.target).Hash
    {Repair-MaesterWhatIfDiscovery -TestsPath $f.root}|Should -Throw '*whatIfSourceUnrecognized*'
    (Get-FileHash $f.target).Hash|Should -BeExactly $before
  }
}
