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
      param([string]$Mode='policy',[switch]$RequireNoMail,[switch]$RuntimeOnly,[switch]$NoCorrelation, [string]$ArchiveContainer='archive', [string]$LatestContainer='latest', [string]$StorageName='')
      $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
      $null = New-Item -ItemType Directory $caseRoot
      $resultPath = Join-Path $caseRoot 'result.json'
      $start = [Diagnostics.ProcessStartInfo]::new()
      $start.FileName = (Get-Process -Id $PID).Path; $start.UseShellExecute=$false
      $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
      foreach ($name in 'TMPDIR','TEMP','TMP') { $start.Environment[$name]=$caseRoot }
      foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'fixtures/Invoke-OfflineAssessment.ps1'),'-RunbookPath',$runbookPath,'-Fixtures',$fixtures,'-ResultPath',$resultPath,'-Mode',$Mode)) { $start.ArgumentList.Add($argument) }
      foreach ($flag in 'RequireNoMail','RuntimeOnly','NoCorrelation') { if ($PSBoundParameters[$flag]) { $start.ArgumentList.Add("-$flag") } }
      foreach ($parameter in 'ArchiveContainer','LatestContainer','StorageName') { if ($PSBoundParameters[$parameter]) { $start.ArgumentList.Add("-$parameter"); $start.ArgumentList.Add($PSBoundParameters[$parameter]) } }
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
    ($r.Uploads -join "`n") | Should -Not -Match '/failed/'
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
    $r.Uploads.Count | Should -BeGreaterThan 0
    foreach ($uri in $r.Uploads) { $uri | Should -Match '^https://offlinestorage\.blob\.core\.windows\.net/archive/failed/[a-f0-9]{32}/(diagnostics\.json|pester-junit\.xml)$' }
    ($r.Output -join "`n") | Should -Not -Match 'MAESTER_ASSESSMENT_RECEIPT_V1:'
    (($r.Output -join "`n") + $r.Console + $r.Error) | Should -Not -Match 'private|PRIVATE_|offline-token'
    $r.RestoredDrift | Should -BeExactly 'unapproved-inherited-drift'
  }
  It 'preserves hidden engine cause in restricted artifacts while failing the original gate' {
    $r = Invoke-OfflineAssessment -Mode engine-error -RequireNoMail
    $r.Error | Should -BeExactly 'assessment.junitErrors'
    $r.Uploads.Count | Should -Be 2
    $r.Mail | Should -BeNullOrEmpty
    $json = ($r.UploadedFiles | Where-Object Uri -Like '*/diagnostics.json').Content
    $diagnostic = $json | ConvertFrom-Json
    $diagnostic.FailureCode | Should -BeExactly 'assessment.junitErrors'
    $diagnostic.DiagnosticOnly | Should -BeTrue
    $diagnostic.RequestedJobId | Should -BeExactly '11111111-1111-4111-8111-111111111111'
    $diagnostic.Entries.Message | Should -Contain 'PRIVATE_ENGINE_CAUSE'
    ($diagnostic.Entries.ScriptStackTrace -join '') | Should -Match 'Invoke-OfflineAssessment'
    $json | Should -Not -Match 'TargetObject|InvocationInfo|offline-token|private-fixture-tenant|private policy findings'
    ($r.UploadedFiles | Where-Object Uri -Like '*/pester-junit.xml').Content | Should -Match 'errors="1"'
    (($r.Output -join "`n") + $r.Console) | Should -Not -Match 'PRIVATE_|private-fixture|offline-token|MAESTER_ASSESSMENT_RECEIPT_V1:'
    ($r.Uploads -join "`n") | Should -Not -Match '/latest/|scm\.|maester-report-'
    ($r.Output -join "`n") | Should -Match 'diagnostics=Published; junit=Published'
  }
  It 'cannot substitute wrong, absent, linked, directory or oversized JUnit: <_>' -ForEach @('engine-wrong-junit','engine-no-junit','engine-symlink-junit','engine-directory-junit','engine-oversized-junit') {
    $r = Invoke-OfflineAssessment -Mode $_ -RequireNoMail
    $r.Error | Should -Match '^assessment\.junit(Invalid|Errors)$'
    $r.Uploads.Count | Should -Be 1
    $r.Uploads[0] | Should -Match '/archive/failed/[a-f0-9]{32}/diagnostics\.json$'
    ($r.Output -join "`n") | Should -Match 'junit=Unavailable'
    ($r.Output -join "`n") | Should -Not -Match 'MAESTER_ASSESSMENT_RECEIPT_V1:'
  }
  It 'does not mask assessment failure with diagnostic transport failure: <_>' -ForEach @('diagnostic-token-failure','diagnostic-upload-failure') {
    $r = Invoke-OfflineAssessment -Mode $_ -RequireNoMail
    $r.Error | Should -BeExactly 'assessment.junitErrors'
    $r.TokenRequests | Should -Be 1
    ($r.Output -join "`n") | Should -Match 'diagnostics=UploadFailed; junit=UploadFailed'
    (($r.Output -join "`n") + $r.Console + $r.Error) | Should -Not -Match 'PRIVATE_|offline-token|MAESTER_ASSESSMENT_RECEIPT_V1:'
    foreach ($uri in $r.Uploads) { $uri | Should -Match '/archive/failed/' }
  }
  It 'keeps original failure if diagnostic extraction fails, while still preserving JUnit' {
    $r = Invoke-OfflineAssessment -Mode diagnostic-projection-failure -RequireNoMail
    $r.Error | Should -BeExactly 'assessment.junitErrors'
    $r.Uploads.Count | Should -Be 1
    $r.Uploads[0] | Should -Match '/archive/failed/[a-f0-9]{32}/pester-junit\.xml$'
    ($r.Output -join "`n") | Should -Match 'diagnostics=Unavailable; junit=Published'
    (($r.Output -join "`n") + $r.Console) | Should -Not -Match 'PRIVATE_|MAESTER_ASSESSMENT_RECEIPT_V1:'
  }
  It 'verifies a custom private archive before diagnostic PUTs' {
    $r = Invoke-OfflineAssessment -Mode engine-error -RequireNoMail -ArchiveContainer private-custom
    $r.Error | Should -BeExactly 'assessment.junitErrors'
    $r.PrivacyRequests | Should -Be 1
    $r.Uploads.Count | Should -Be 2
    foreach ($uri in $r.Uploads) { $uri | Should -Match '/private-custom/failed/' }
  }
  It 'rejects unsafe diagnostic destinations before token or HTTP access: <Archive>/<Latest>/<Storage>' -ForEach @(
    @{Archive='latest';Latest='latest';Storage=''}, @{Archive='$web';Latest='latest';Storage=''},
    @{Archive='archive';Latest='archive';Storage=''}, @{Archive='archive';Latest='latest';Storage='bad/account'},
    @{Archive='bad--container';Latest='latest';Storage=''}, @{Archive='archive/other';Latest='latest';Storage=''}
  ) {
    $r = Invoke-OfflineAssessment -Mode engine-error -RequireNoMail -ArchiveContainer $Archive -LatestContainer $Latest -StorageName $Storage
    $r.Error | Should -BeExactly 'assessment.junitErrors'
    $r.PrivacyRequests | Should -Be 0
    $r.TokenRequests | Should -Be 0
    $r.Uploads.Count | Should -Be 0
    ($r.Output -join "`n") | Should -Match 'diagnostics=DestinationRejected; junit=DestinationRejected'
  }
  It 'cannot publish diagnostics when container privacy cannot be established: <_>' -ForEach @('diagnostic-head-throw','diagnostic-head-denied','diagnostic-head-redirect','diagnostic-public-container','diagnostic-public-empty-header','diagnostic-head-malformed') {
    $r = Invoke-OfflineAssessment -Mode $_ -RequireNoMail
    $r.Error | Should -BeExactly 'assessment.junitErrors'
    $r.PrivacyRequests | Should -Be 1
    $r.Uploads.Count | Should -Be 0
    ($r.Output -join "`n") | Should -Not -Match 'diagnostics=Published|junit=Published|MAESTER_ASSESSMENT_RECEIPT_V1:'
    (($r.Output -join "`n") + $r.Console) | Should -Not -Match 'PRIVATE_|offline-token'
  }
  It 'preserves failure without storage and does not request a storage token' {
    $r = Invoke-OfflineAssessment -Mode engine-no-storage -RequireNoMail
    $r.Error | Should -BeExactly 'assessment.junitErrors'
    $r.TokenRequests | Should -Be 0
    $r.Uploads.Count | Should -Be 0
    ($r.Output -join "`n") | Should -Match 'diagnostics=Disabled; junit=Disabled'
    ($r.Output -join "`n") | Should -Not -Match 'MAESTER_ASSESSMENT_RECEIPT_V1:'
  }
  It 'uses a unique failed prefix even when caller correlation is repeated or absent' {
    $first = Invoke-OfflineAssessment -Mode engine-error -RequireNoMail
    $second = Invoke-OfflineAssessment -Mode engine-error -RequireNoMail -NoCorrelation
    $first.Uploads[0] | Should -Not -BeExactly $second.Uploads[0]
    (($second.UploadedFiles | Where-Object Uri -Like '*/diagnostics.json').Content | ConvertFrom-Json).RequestedJobId | Should -BeNullOrEmpty
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
    $r.Uploads.Count | Should -Be 2
    foreach ($uri in $r.Uploads) { $uri | Should -Match '/archive/failed/' }
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
