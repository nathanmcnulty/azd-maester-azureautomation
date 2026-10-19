Describe 'Assessment evidence through the complete maintained Automation runbook' {
  BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $runbookPath = Join-Path $repoRoot 'scripts/Invoke-MaesterAutomationRunbook.ps1'
    $runbookText = Get-Content $runbookPath -Raw
    Import-Module (Join-Path $repoRoot 'scripts/Maester.AutomationEvidence.psm1') -Force
    $locks = @{}
    foreach ($match in [regex]::Matches($runbookText, "'(?<Name>[A-Za-z0-9.]+)' = @\{ Version = '(?<Version>[0-9.]+)'; Sha256 = '(?<Hash>[A-F0-9]{64})' \}")) {
      $locks[$match.Groups['Name'].Value] = @{ Version=$match.Groups['Version'].Value; Hash=$match.Groups['Hash'].Value }
    }
    $fixtures = Join-Path $TestDrive 'fixtures'
    New-Item -ItemType Directory $fixtures | Out-Null
    foreach ($name in $locks.Keys) {
      $source = Join-Path $fixtures $name
      New-Item -ItemType Directory $source | Out-Null
      $version = $locks[$name].Version
      Set-Content (Join-Path $source "$name.psd1") "@{RootModule='$name.psm1'; ModuleVersion='$version'; GUID='$([guid]::NewGuid())'; FunctionsToExport=@(); CmdletsToExport=@(); AliasesToExport=@()}"
      Set-Content (Join-Path $source "$name.psm1") 'Export-ModuleMember -Function @() -Cmdlet @() -Alias @()'
      if ($name -eq 'Maester') {
        New-Item -ItemType Directory (Join-Path $source 'maester-tests') | Out-Null
        Set-Content (Join-Path $source 'maester-tests/Fixture.Tests.ps1') '# Offline discovery fixture'
      }
      [IO.Compression.ZipFile]::CreateFromDirectory($source, (Join-Path $fixtures "$name.$version.nupkg"))
    }
    $locks | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $fixtures 'locks.json')
    function Invoke-OfflineAssessment {
      param([string]$Mode='policy',[switch]$RequireNoMail,[switch]$RuntimeOnly,[switch]$NoCorrelation)
      $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
      $null = New-Item -ItemType Directory $caseRoot
      $resultPath = Join-Path $caseRoot 'result.json'
      $start = [Diagnostics.ProcessStartInfo]::new()
      $start.FileName = (Get-Process -Id $PID).Path; $start.UseShellExecute=$false
      $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
      foreach ($name in 'TMPDIR','TEMP','TMP') { $start.Environment[$name]=$caseRoot }
      foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'fixtures/Invoke-OfflineAssessment.ps1'),'-RunbookPath',$runbookPath,'-Fixtures',$fixtures,'-ResultPath',$resultPath,'-Mode',$Mode)) { $start.ArgumentList.Add($argument) }
      foreach ($flag in 'RequireNoMail','RuntimeOnly','NoCorrelation') { if ($PSBoundParameters[$flag]) { $start.ArgumentList.Add("-$flag") } }
      $process = [Diagnostics.Process]::Start($start)
      try {
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill($true); throw 'Offline assessment timed out.' }
        if (-not (Test-Path $resultPath)) { throw "Harness failed: $($stdout.Result) $($stderr.Result)" }
        $r = Get-Content $resultPath -Raw | ConvertFrom-Json
        $r | Add-Member ExitCode $process.ExitCode
        $r | Add-Member Console ($stdout.Result + $stderr.Result)
        $r
      }
      finally { $process.Dispose() }
    }
    function Get-OfflineReceipt($Result) {
      $lines = @($Result.Output | Where-Object { $_ -like 'MAESTER_ASSESSMENT_RECEIPT_V1:*' })
      $lines.Count | Should -Be 1
      $lines[0].Substring('MAESTER_ASSESSMENT_RECEIPT_V1:'.Length) | ConvertFrom-Json -AsHashtable -DateKind String
    }
  }
  It 'accepts legitimate policy failures and publishes a sanitized job-correlated receipt' {
    $r = Invoke-OfflineAssessment -RequireNoMail
    $r.ExitCode | Should -Be 0 -Because "$($r.Error) $($r.ErrorDetails)"
    $r.Invokes | Should -Be 1
    $r.Auth | Should -Be 2
    $r.Uploads.Count | Should -Be 2
    $receipt = Get-OfflineReceipt $r
    $receipt.Assessment.Counts.FailedCount | Should -Be 1
    $receipt.Publication.Mail | Should -BeExactly 'Disabled'
    $receipt.Runtime.Modules.Count | Should -Be 7
    $r.Drift | Should -BeNullOrEmpty
    $r.RestoredDrift | Should -BeExactly 'unapproved-inherited-drift'
    $e = Read-AutomationJobEvidence -Output ($r.Output -join "`n") -JobContent $runbookText -ExpectedContent $runbookText -JobId $receipt.RequestedJobId -NotBefore ([datetimeoffset]::UtcNow.AddMinutes(-1)) -RequireNoMail
    $e.Scope | Should -BeExactly 'NoMailAssessmentHealthAndPublication'
    (($r.Output -join "`n") + $r.Console) | Should -Not -Match 'private|offline-token|DIAGNOSTIC|ScriptBlock|ErrorRecord'
  }
  It 'fails closed for <_> before report publication or assessment receipt' -ForEach @('throw','nonterminating','stale-html-only','duplicate-result','zero','no-report','wrong-report','no-junit','maester-error','runtime-error','engine-error','core-missing') {
    $r = Invoke-OfflineAssessment -Mode $_
    $r.ExitCode | Should -Be 1
    $r.Error | Should -Match '^assessment\.'
    $r.Invokes | Should -Be 1
    $r.Uploads.Count | Should -Be 0
    ($r.Output -join "`n") | Should -Not -Match 'MAESTER_ASSESSMENT_RECEIPT_V1:'
    (($r.Output -join "`n") + $r.Console + $r.Error) | Should -Not -Match 'private|DIAGNOSTIC|offline-token'
    $r.RestoredDrift | Should -BeExactly 'unapproved-inherited-drift'
  }
  It 'preserves scheduled ordinary execution without validation metadata' {
    $r = Invoke-OfflineAssessment -NoCorrelation
    $r.ExitCode | Should -Be 0 -Because $r.Error
    (Get-OfflineReceipt $r).RequestedJobId | Should -BeNullOrEmpty
  }
  It 'preserves upstream inline mail without claiming delivery' {
    $r = Invoke-OfflineAssessment -Mode mail
    $r.ExitCode | Should -Be 0 -Because $r.Error
    $r.Mail | Should -BeExactly 'private-recipient@example.invalid'
    (Get-OfflineReceipt $r).Publication.Mail | Should -BeExactly 'UpstreamUnverified'
    (($r.Output -join "`n") + $r.Console) | Should -Not -Match 'private-recipient|DIAGNOSTIC'
  }
  It 'rejects resolved Automation-variable mail before invoking Maester for qualification' {
    $r = Invoke-OfflineAssessment -Mode mail -RequireNoMail
    $r.ExitCode | Should -Be 1
    $r.Error | Should -BeExactly 'assessment.mailMustBeDisabled'
    $r.Invokes | Should -Be 0
    $r.Uploads.Count | Should -Be 0
  }
  It 'does not claim that a later runtime failure retracts upstream inline mail' {
    $r = Invoke-OfflineAssessment -Mode mail-runtime-error
    $r.ExitCode | Should -Be 1
    $r.Mail | Should -BeExactly 'private-recipient@example.invalid'
    $r.Uploads.Count | Should -Be 0
    ($r.Output -join "`n") | Should -Not -Match 'MAESTER_ASSESSMENT_RECEIPT_V1:'
  }
  It 'records optional locked imports and successful Web App publication' {
    $r = Invoke-OfflineAssessment -Mode optional
    $r.ExitCode | Should -Be 0 -Because $r.Error
    $receipt = Get-OfflineReceipt $r
    $receipt.Runtime.Modules.ExchangeOnlineManagement | Should -BeExactly '3.10.1'
    $receipt.Runtime.Modules.MicrosoftTeams | Should -BeExactly '8.0.0'
    $r = Invoke-OfflineAssessment -Mode webapp
    $r.ExitCode | Should -Be 0 -Because $r.Error
    (Get-OfflineReceipt $r).Publication.WebApp | Should -BeExactly 'Published'
    $r.Uploads.Count | Should -Be 3
  }
  It 'does not qualify incomplete publication <_>' -ForEach @('archive-failure','no-storage','webapp-incomplete') {
    $r = Invoke-OfflineAssessment -Mode $_
    $r.ExitCode | Should -Be 0 -Because $r.Error
    $receipt = Get-OfflineReceipt $r
    { Read-AutomationJobEvidence -Output ($r.Output -join "`n") -JobContent $runbookText -ExpectedContent $runbookText -JobId $receipt.RequestedJobId -NotBefore ([datetimeoffset]::UtcNow.AddMinutes(-1)) } | Should -Throw '*jobEvidenceInvalidOrMismatched*'
  }
  It 'fails publication <_> without a receipt' -ForEach @('latest-failure','webapp-failure') {
    $r = Invoke-OfflineAssessment -Mode $_
    $r.ExitCode | Should -Be 1
    $r.Error | Should -Match '^assessment\.'
    ($r.Output -join "`n") | Should -Not -Match 'MAESTER_ASSESSMENT_RECEIPT_V1:'
  }
  It 'keeps runtime-only before authentication, mail configuration, and assessment' {
    $r = Invoke-OfflineAssessment -Mode mail -RuntimeOnly -NoCorrelation -RequireNoMail
    $r.ExitCode | Should -Be 0 -Because $r.Error
    $r.Auth | Should -Be 0
    $r.Invokes | Should -Be 0
    $r.Uploads.Count | Should -Be 0
    ($r.Output -join "`n") | Should -Match 'Maester.RuntimeValidation'
    ($r.Output -join "`n") | Should -Not -Match 'MAESTER_ASSESSMENT_RECEIPT_V1:'
  }
}
