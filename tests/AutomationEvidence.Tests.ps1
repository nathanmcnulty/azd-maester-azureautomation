BeforeAll {
  $root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $root 'scripts/Maester.AutomationEvidence.psm1') -Force
  . (Join-Path $PSScriptRoot 'fixtures/AssessmentEvidence.ps1')
  $runbookContent = Get-Content (Join-Path $root 'scripts/Invoke-MaesterAutomationRunbook.ps1') -Raw
}
Describe 'Strict Automation job receipt and source binding' {
  BeforeEach {
    $receipt = New-TestAutomationReceipt
    $expected = @{ JobId = $receipt.RequestedJobId; Packages = Get-AutomationEvidencePackages $runbookContent; NotBefore = [datetimeoffset]::UtcNow.AddMinutes(-1) }
    $job = @{ JobId = $receipt.RequestedJobId; NotBefore = $expected.NotBefore; JobContent = $runbookContent; ExpectedContent = $runbookContent }
  }
  It 'accepts genuine findings on the exact observed host with explicit no-mail scope' {
    $r = Read-AutomationJobEvidence -Output ('ordinary output' + "`nMAESTER_ASSESSMENT_RECEIPT_V1:" + ($receipt | ConvertTo-Json -Depth 8 -Compress)) @job -RequireNoMail
    $r.Scope | Should -BeExactly 'NoMailAssessmentHealthAndPublication'
    $r.Receipt.Assessment.Counts.FailedCount | Should -Be 1
    $r.RunbookSha256 | Should -BeExactly (Get-AutomationEvidenceSource $runbookContent)
  }
  It 'preserves inline mail only as unverified outside qualification' {
    $receipt.Publication.Mail = 'UpstreamUnverified'
    (Assert-AutomationAssessmentReceipt -Json ($receipt | ConvertTo-Json -Depth 8) @expected).Publication.Mail | Should -BeExactly 'UpstreamUnverified'
    { Assert-AutomationAssessmentReceipt -Json ($receipt | ConvertTo-Json -Depth 8) @expected -RequireNoMail } | Should -Throw '*receiptInvalidOrMismatched*'
  }
  It 'rejects receipt fault <_>' -ForEach @('old-job','stale','future','schema-string','schema-boolean','count-boolean','count-string','negative','fraction','zero','errors','junit','core','hash','archive','latest','mail','webapp','modules','module-count-key','module-extra','core-count-key','extra-field','unknown-kind','edition','wrong-preview','preview-suffix','preview-newline','preview-case','higher-preview','preview-net11','net9') {
    switch ($_) {
      'old-job' { $receipt.RequestedJobId = [guid]::NewGuid().ToString() }
      'stale' { $receipt.StartedAt = [datetimeoffset]::UtcNow.AddDays(-1).ToString('o') }
      'future' { $receipt.CompletedAt = [datetimeoffset]::UtcNow.AddDays(1).ToString('o') }
      'schema-string' { $receipt.SchemaVersion = '1' }
      'schema-boolean' { $receipt.SchemaVersion = $true }
      'count-boolean' { $receipt.Assessment.Counts.PassedCount = $true }
      'count-string' { $receipt.Assessment.Counts.PassedCount = '1' }
      'negative' { $receipt.Assessment.Counts.PassedCount = -1 }
      'fraction' { $receipt.Assessment.Counts.PassedCount = 1.5 }
      'zero' { $receipt.Assessment.Counts.TotalCount = 0 }
      'errors' { $receipt.Assessment.Counts.ErrorCount = 23 }
      'junit' { $receipt.Assessment.JunitErrors = 1 }
      'core' { $receipt.Assessment.CoreCases['MT.1068'] = 'Skipped' }
      'hash' { $receipt.Assessment.ReportSha256 = 'a'*64 + "`n" }
      'archive' { $receipt.Publication.Archive = 'Failed' }
      'latest' { $receipt.Publication.Latest = 'Disabled' }
      'mail' { $receipt.Publication.Mail = 'Delivered' }
      'webapp' { $receipt.Publication.WebApp = 'IncompleteConfiguration' }
      'modules' { $receipt.Runtime.Modules.Maester = '2.1.0' }
      'module-count-key' { $receipt.Runtime.Modules.Count = 7 }
      'module-extra' { $receipt.Runtime.Modules['Unexpected'] = '1.0.0' }
      'core-count-key' { $receipt.Assessment.CoreCases.Count = 2 }
      'extra-field' { $receipt.Unexpected = 'private data' }
      'unknown-kind' { $receipt.Kind = 'Maester.RuntimeValidation' }
      'edition' { $receipt.Runtime.Edition = 'Desktop' }
      'wrong-preview' { $receipt.Runtime.PowerShell = '7.6.0-preview.6' }
      'preview-suffix' { $receipt.Runtime.PowerShell = '7.6.0-preview.5+provider.1' }
      'preview-newline' { $receipt.Runtime.PowerShell += "`n" }
      'preview-case' { $receipt.Runtime.PowerShell = '7.6.0-Preview.5' }
      'higher-preview' { $receipt.Runtime.PowerShell = '7.7.0-preview.1' }
      'preview-net11' { $receipt.Runtime.DotNet = '11.0.0' }
      'net9' { $receipt.Runtime.DotNet = '9.0.10' }
    }
    { Assert-AutomationAssessmentReceipt -Json ($receipt | ConvertTo-Json -Depth 8) @expected } | Should -Throw '*receiptInvalidOrMismatched*'
  }
  It 'rejects array-valued string <_>' -ForEach @('Kind','RequestedJobId','StartedAt','CompletedAt','Runtime.PowerShell','Runtime.DotNet','Runtime.Edition','Runtime.Modules.Maester','Assessment.Outcome','Assessment.ReportSha256','Assessment.JunitSha256','Assessment.CoreCases.MT.1068','Publication.Archive','Publication.Latest','Publication.WebApp','Publication.Mail') {
    $keys = $_ -split '\.', 3; $object = $receipt
    if ($_.StartsWith('Assessment.CoreCases.')) { $object = $receipt.Assessment.CoreCases; $key = 'MT.1068' }
    else { for ($i=0; $i -lt $keys.Count - 1; $i++) { $object = $object[$keys[$i]] }; $key = $keys[-1] }
    $object[$key] = @($object[$key], $object[$key])
    { Assert-AutomationAssessmentReceipt -Json ($receipt | ConvertTo-Json -Depth 8) @expected } | Should -Throw '*receiptInvalidOrMismatched*'
  }
  It 'accepts stable <Version> on .NET <DotNet>' -ForEach @(
    @{ Version='7.6.0'; DotNet='10.0.0' }, @{ Version='7.6.6'; DotNet='10.0.12' }, @{ Version='7.7.0'; DotNet='10.0.12' }, @{ Version='8.0.0'; DotNet='11.0.0' }, @{ Version='7.6.0+provider.1'; DotNet='10.0.12' }
  ) {
    $receipt.Runtime.PowerShell = $Version; $receipt.Runtime.DotNet = $DotNet
    (Assert-AutomationAssessmentReceipt -Json ($receipt | ConvertTo-Json -Depth 8) @expected).Runtime.PowerShell | Should -BeExactly $Version
  }
  It 'enforces requested optional workload and publication expectations' {
    foreach ($flag in 'ExpectExchangeImport','ExpectTeamsImport','ExpectWebApp') {
      $flags = @{ $flag = $true }
      { Assert-AutomationAssessmentReceipt -Json ($receipt | ConvertTo-Json -Depth 8) @expected @flags } | Should -Throw
    }
    $receipt.Runtime.Modules.ExchangeOnlineManagement = '3.10.1'; $receipt.Runtime.Modules.MicrosoftTeams = '8.0.0'; $receipt.Publication.WebApp = 'Published'
    Assert-AutomationAssessmentReceipt -Json ($receipt | ConvertTo-Json -Depth 8) @expected -ExpectExchangeImport -ExpectTeamsImport -ExpectWebApp | Should -Not -BeNullOrEmpty
  }
  It 'rejects malformed, duplicate-key and oversized receipt JSON' -ForEach @('{broken','{"SchemaVersion":1,"schemaVersion":1}',(' ' * 16385)) {
    { Assert-AutomationAssessmentReceipt -Json $_ @expected } | Should -Throw '*receiptInvalidOrMismatched*'
  }
  It 'rejects source/output fault <_> even for a Completed job' -ForEach @('source','source-whitespace','source-shape','source-empty','missing','duplicate','inline-marker','oversized','output-shape','truncated') {
    $output = 'MAESTER_ASSESSMENT_RECEIPT_V1:' + ($receipt | ConvertTo-Json -Depth 8 -Compress)
    switch ($_) {
      'source' { $job.JobContent = '# older published script' }
      'source-whitespace' { $job.JobContent += ' ' }
      'source-shape' { $job.JobContent = @($runbookContent) }
      'source-empty' { $job.JobContent = '' }
      'missing' { $output = 'Completed with old HTML' }
      'duplicate' { $output += "`n$output" }
      'inline-marker' { $output = 'incidental ' + $output }
      'oversized' { $output = 'x' * 1048577 }
      'output-shape' { $output = @{ output = $output } }
      'truncated' { $output = $output.Substring(0, $output.Length-4) }
    }
    { Read-AutomationJobEvidence -Output $output @job } | Should -Throw '*jobEvidenceInvalidOrMismatched*'
  }
  It 'permits only BOM and CRLF source normalization' {
    $job.JobContent = [string][char]0xFEFF + $runbookContent.Replace("`n", "`r`n")
    Read-AutomationJobEvidence -Output ('MAESTER_ASSESSMENT_RECEIPT_V1:' + ($receipt | ConvertTo-Json -Depth 8 -Compress)) @job | Should -Not -BeNullOrEmpty
  }
  It 'keeps actual runtime-only imports in a distinct sanitized scope' {
    $r = Read-AutomationJobEvidence -Output (New-TestRuntimeReceipt | ConvertTo-Json -Depth 5 -Compress) @job -RuntimeValidationOnly
    $r.Scope | Should -BeExactly 'RuntimeImportsOnly'
    ($r | ConvertTo-Json -Depth 6) | Should -Not -Match '/tmp/private|Assessment|Publication'
    $r.Runtime.Modules.Count | Should -Be 7
  }
  It 'rejects runtime receipt fault <_>' -ForEach @('missing','duplicate','wrong-kind','wrong-version','duplicate-module','missing-module','array-name','extra-field','extra-assessment') {
    $case = $_
    $runtime = New-TestRuntimeReceipt
    switch ($_) {
      'wrong-kind' { $runtime.Kind = 'MaesterAutomationAssessment' }
      'wrong-version' { $runtime.Modules[0].Version = '1.0.0' }
      'duplicate-module' { $runtime.Modules[1] = $runtime.Modules[0] }
      'missing-module' { $runtime.Modules = $runtime.Modules[0..5] }
      'array-name' { $runtime.Modules[0].Name = @($runtime.Modules[0].Name) }
      'extra-field' { $runtime.Private = 'diagnostics' }
    }
    $output = $runtime | ConvertTo-Json -Depth 6 -Compress
    if ($case -eq 'missing') { $output = 'Completed' }
    if ($case -eq 'duplicate') { $output += "`n$output" }
    if ($case -eq 'extra-assessment') { $output += "`nMAESTER_ASSESSMENT_RECEIPT_V1:{}" }
    { Read-AutomationJobEvidence -Output $output @job -RuntimeValidationOnly } | Should -Throw '*jobEvidenceInvalidOrMismatched*'
  }
}
