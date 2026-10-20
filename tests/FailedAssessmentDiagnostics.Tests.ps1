BeforeAll {
  $runbook = Join-Path $PSScriptRoot '../scripts/Invoke-MaesterAutomationRunbook.ps1'
  $tokens = $null; $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($runbook, [ref]$tokens, [ref]$parseErrors)
  foreach ($name in 'New-FailedAssessmentDiagnostic','Publish-FailedAssessmentArtifacts') {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
  }
  function New-DiagnosticRecord([string]$Message, [string]$Id = 'engine') {
    [Management.Automation.ErrorRecord]::new([IO.IOException]::new($Message), $Id, [Management.Automation.ErrorCategory]::NotSpecified, [pscustomobject]@{ Secret='UNSAFE_TARGET_SECRET' })
  }
  $correlation = @{ InvocationId = 'a'*32; RequestedJobId = '11111111-1111-4111-8111-111111111111'; FailureCode = 'assessment.junitErrors' }
}
Describe 'Bounded private failed-assessment diagnostics' {
  It 'normalizes ErrorRecord and RuntimeException without arbitrary object serialization' {
    $record = New-DiagnosticRecord 'private engine cause'
    $wrapper = [Management.Automation.RuntimeException]::new('outer', $record.Exception, $record)
    $json = New-FailedAssessmentDiagnostic @correlation -DiagnosticErrors @($record, $wrapper, [pscustomobject]@{ Message='UNSAFE_OBJECT_SECRET'; ErrorRecord=$record })
    $d = $json | ConvertFrom-Json
    $d.Entries.Count | Should -Be 1
    $d.Entries[0].Message | Should -BeExactly 'private engine cause'
    $d.RepeatedEntryCount | Should -Be 1
    $d.UnsupportedEntryCount | Should -Be 1
    $json | Should -Not -Match 'UNSAFE_|TargetObject|InvocationInfo|ErrorRecord|innerException'
    @($d.Entries[0].PSObject.Properties.Name) | Should -Be @('ErrorId','ExceptionType','Message','ScriptStackTrace','ExceptionStackTrace','TextTruncated')
  }
  It 'deduplicates and prioritizes a late engine cause after repeated and unique policy control flow' {
    $records = @(for ($i=0; $i -lt 200; $i++) { New-DiagnosticRecord "policy $($i % 40)" 'PesterAssertionFailed' })
    $records += New-DiagnosticRecord 'late engine cause'
    $d = New-FailedAssessmentDiagnostic @correlation -DiagnosticErrors $records | ConvertFrom-Json
    $d.Entries[0].Message | Should -BeExactly 'late engine cause'
    $d.Entries.Count | Should -Be 9
    $d.RepeatedEntryCount | Should -BeGreaterThan 0
    $d.OmittedEntryCount | Should -BeGreaterThan 0
    $d.EntriesTruncated | Should -BeTrue
    $d.DiagnosticOnly | Should -BeTrue
  }
  It 'caps entries, individual text and serialized UTF-8 bytes and marks clipping' {
    $records = @(for ($i=0; $i -lt 100; $i++) { New-DiagnosticRecord ("$i" + ([string][char]0x0001)*10000) ("id$i" + 'x'*500) })
    $json = New-FailedAssessmentDiagnostic @correlation -DiagnosticErrors $records
    $d = $json | ConvertFrom-Json
    [Text.Encoding]::UTF8.GetByteCount($json) | Should -BeLessOrEqual 262144
    $d.Entries.Count | Should -BeLessOrEqual 32
    $d.OmittedEntryCount | Should -BeGreaterThan 0
    $d.TextTruncated | Should -BeTrue
    $d.EntriesTruncated | Should -BeTrue
    foreach ($entry in $d.Entries) { $entry.Message.Length | Should -BeLessOrEqual 2048; $entry.ErrorId.Length | Should -BeLessOrEqual 256 }
  }
  It 'has a useful bounded empty diagnostic when no supported records exist' {
    $d = New-FailedAssessmentDiagnostic @correlation -DiagnosticErrors $null | ConvertFrom-Json
    $d.SourceEntryCount | Should -Be 0
    $d.Entries.Count | Should -Be 0
    $d.FailureCode | Should -BeExactly 'assessment.junitErrors'
  }
}
