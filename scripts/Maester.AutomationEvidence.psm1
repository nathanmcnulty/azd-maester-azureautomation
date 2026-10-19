Set-StrictMode -Version Latest

# Deliberately separate framework health from policy compliance. These are two
# unconditional core tests in the locked Maester 2.3.0 suite, not a coverage claim.
$script:CoreCases = [ordered]@{
  'MT.1068' = 'Maester/Entra/Test-MtTenantCreationRestricted.Tests.ps1'
  'MT.1069' = 'Maester/Entra/Test-MtSecurityGroupCreationRestricted.Tests.ps1'
}

function Get-EvidenceCount {
  param($Value)
  if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or
      $Value -isnot [ValueType] -or $Value -lt 0 -or $Value -gt [int]::MaxValue -or
      [decimal]$Value -ne [math]::Truncate([decimal]$Value)) { throw 'assessment.invalidCount' }
  [int]$Value
}

function Assert-EvidenceObject {
  param($Value, [string[]]$Keys)
  if ($Value -isnot [Collections.IDictionary] -or $Value.get_Count() -ne $Keys.Count) { throw 'validation.receiptShape' }
  foreach ($key in $Value.Keys) { if ($key -cnotin $Keys) { throw 'validation.receiptShape' } }
}

function Assert-EvidenceStrings {
  param([Collections.IDictionary]$Value, [string[]]$Keys)
  foreach ($key in $Keys) {
    if ($Value[$key] -isnot [string]) { throw 'validation.receiptScalarRequired' }
  }
}

function ConvertFrom-MaesterReceiptJson {
  param([Parameter(Mandatory)][string]$Json)
  if ($Json.Length -gt 16384) { throw 'validation.receiptOversized' }
  $doc = [Text.Json.JsonDocument]::Parse($Json)
  try {
    $stack = [Collections.Generic.Stack[Text.Json.JsonElement]]::new()
    $stack.Push($doc.RootElement)
    while ($stack.Count) {
      $element = $stack.Pop()
      if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $element.EnumerateObject()) {
          if (-not $names.Add($property.Name)) { throw 'validation.receiptDuplicateKey' }
          $stack.Push($property.Value)
        }
      }
      elseif ($element.ValueKind -eq [Text.Json.JsonValueKind]::Array) { foreach ($item in $element.EnumerateArray()) { $stack.Push($item) } }
    }
  }
  finally { $doc.Dispose() }
  ConvertFrom-Json -InputObject $Json -AsHashtable -DateKind String -ErrorAction Stop
}

function Assert-AutomationEvidenceRuntime {
  param([string]$PowerShell, [string]$DotNet, [string]$Edition = 'Core')
  if ($PowerShell -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z' -or
      $DotNet -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?\z' -or $Edition -cne 'Core') { throw 'validation.runtimeInvalid' }
  $version = [System.Management.Automation.SemanticVersion]$PowerShell
  $netVersion = [version]$DotNet
  $stable = [string]::IsNullOrEmpty($version.PreReleaseLabel) -and $version -ge [version]'7.6'
  $observed = $PowerShell -ceq '7.6.0-preview.5' -and $netVersion.Major -eq 10
  if ((-not $stable -and -not $observed) -or $netVersion.Major -lt 10) { throw 'validation.runtimeInvalid' }
}

function Get-AutomationEvidenceSource {
  param([Parameter(Mandatory)][string]$Content)
  # Same text normalizations as the maintained publication verifier: BOM and CRLF.
  # Do not trim trailing whitespace or otherwise rewrite executable source.
  $canonical = $Content.TrimStart([char]0xFEFF).Replace("`r`n", "`n")
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
}

function Get-AutomationEvidencePackages {
  param([Parameter(Mandatory)][string]$RunbookContent)
  $packages = @{}
  foreach ($match in [regex]::Matches($RunbookContent, "'(?<Name>[A-Za-z0-9.]+)' = @\{ Version = '(?<Version>[0-9.]+)'; Sha256 = '(?<Hash>[A-F0-9]{64})' \}")) {
    $name = $match.Groups['Name'].Value
    if ($packages.ContainsKey($name)) { throw 'validation.packageLockInvalid' }
    $packages[$name] = $match.Groups['Version'].Value
  }
  $expected = @('NuGet','PackageManagement','PowerShellGet','Az.Accounts','Microsoft.Graph.Authentication','Pester','Maester','ExchangeOnlineManagement','MicrosoftTeams')
  Assert-EvidenceObject $packages $expected
  $packages
}

function Assert-AutomationAssessmentReceipt {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Json,
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][Collections.IDictionary]$Packages,
    [Parameter(Mandatory)][datetimeoffset]$NotBefore,
    [datetimeoffset]$Now = [datetimeoffset]::UtcNow,
    [switch]$RequireNoMail,
    [switch]$ExpectWebApp,
    [switch]$ExpectExchangeImport,
    [switch]$ExpectTeamsImport
  )
  $ErrorActionPreference = 'Stop'
  try {
    $r = ConvertFrom-MaesterReceiptJson $Json
    Assert-EvidenceObject $r @('SchemaVersion','Kind','RequestedJobId','StartedAt','CompletedAt','Runtime','Assessment','Publication')
    Assert-EvidenceObject $r.Runtime @('PowerShell','DotNet','Edition','Modules')
    $required = @('NuGet','PackageManagement','PowerShellGet','Az.Accounts','Microsoft.Graph.Authentication','Pester','Maester')
    if ($ExpectExchangeImport) { $required += 'ExchangeOnlineManagement' }
    if ($ExpectTeamsImport) { $required += 'MicrosoftTeams' }
    if ($r.Runtime.Modules -isnot [Collections.IDictionary]) { throw 'modules' }
    foreach ($name in $required) { if (-not $r.Runtime.Modules.Contains($name)) { throw 'modules' } }
    foreach ($name in $r.Runtime.Modules.Keys) {
      if ($name -cnotin @($Packages.Keys) -or $r.Runtime.Modules[$name] -isnot [string] -or
          $r.Runtime.Modules[$name] -cne $Packages[$name]) { throw 'modules' }
    }
    Assert-EvidenceObject $r.Assessment @('Outcome','Counts','CoreCases','JunitErrors','JunitTests','ReportSha256','JunitSha256')
    Assert-EvidenceObject $r.Assessment.Counts @('TotalCount','PassedCount','FailedCount','ErrorCount','InvestigateCount','SkippedCount','NotRunCount')
    Assert-EvidenceObject $r.Assessment.CoreCases @($script:CoreCases.Keys)
    Assert-EvidenceObject $r.Publication @('Archive','Latest','WebApp','Mail')
    Assert-EvidenceStrings $r @('Kind','RequestedJobId','StartedAt','CompletedAt')
    Assert-EvidenceStrings $r.Runtime @('PowerShell','DotNet','Edition')
    Assert-EvidenceStrings $r.Assessment @('Outcome','ReportSha256','JunitSha256')
    Assert-EvidenceStrings $r.Assessment.CoreCases @($script:CoreCases.Keys)
    Assert-EvidenceStrings $r.Publication @($r.Publication.Keys)
    if ((Get-EvidenceCount $r.SchemaVersion) -ne 1 -or $r.Kind -cne 'MaesterAutomationAssessment' -or $r.RequestedJobId -cne $JobId) { throw 'identity' }
    $started = [datetimeoffset]::ParseExact($r.StartedAt, 'o', [Globalization.CultureInfo]::InvariantCulture)
    $completed = [datetimeoffset]::ParseExact($r.CompletedAt, 'o', [Globalization.CultureInfo]::InvariantCulture)
    if ($started -lt $NotBefore.AddMinutes(-2) -or $completed -lt $started -or $completed -gt $Now.AddMinutes(2)) { throw 'time' }
    Assert-AutomationEvidenceRuntime $r.Runtime.PowerShell $r.Runtime.DotNet $r.Runtime.Edition
    $a = $r.Assessment
    if ($a.Outcome -cne 'Completed' -or (Get-EvidenceCount $a.Counts.ErrorCount) -ne 0 -or (Get-EvidenceCount $a.JunitErrors) -ne 0) { throw 'assessment' }
    $sum = 0L
    foreach ($state in 'Passed','Failed','Error','Investigate','Skipped','NotRun') { $sum += Get-EvidenceCount $a.Counts[$state + 'Count'] }
    if ($sum -ne (Get-EvidenceCount $a.Counts.TotalCount) -or $sum -eq 0 -or $sum -ne (Get-EvidenceCount $a.JunitTests) -or
        ($a.Counts.PassedCount + $a.Counts.FailedCount) -lt $script:CoreCases.Count) { throw 'counts' }
    foreach ($id in $script:CoreCases.Keys) { if ($a.CoreCases[$id] -cnotin @('Passed','Failed')) { throw 'core' } }
    foreach ($name in 'ReportSha256','JunitSha256') { if ($a[$name] -cnotmatch '^[0-9a-f]{64}\z') { throw 'hash' } }
    if ($r.Publication.Archive -cne 'Published' -or $r.Publication.Latest -cne 'Published' -or
        $r.Publication.WebApp -cnotin @('Published','Disabled') -or ($ExpectWebApp -and $r.Publication.WebApp -cne 'Published') -or
        $r.Publication.Mail -cnotin @('Disabled','UpstreamUnverified') -or ($RequireNoMail -and $r.Publication.Mail -cne 'Disabled')) { throw 'publication' }
    $r
  }
  catch { throw 'validation.receiptInvalidOrMismatched' }
}

function Read-AutomationJobEvidence {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowNull()]$Output,
    [Parameter(Mandatory)][AllowNull()]$JobContent,
    [Parameter(Mandatory)][string]$ExpectedContent,
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][datetimeoffset]$NotBefore,
    [switch]$RuntimeValidationOnly,
    [switch]$RequireNoMail,
    [switch]$ExpectWebApp,
    [switch]$ExpectExchangeImport,
    [switch]$ExpectTeamsImport
  )
  $ErrorActionPreference = 'Stop'
  try {
    if ($Output -isnot [string] -or $Output.Length -gt 1048576 -or $JobContent -isnot [string] -or
        $JobContent.Length -gt 1048576 -or [string]::IsNullOrEmpty($JobContent)) { throw 'shape' }
    $source = Get-AutomationEvidenceSource $ExpectedContent
    if ((Get-AutomationEvidenceSource $JobContent) -cne $source) { throw 'source' }
    $packages = Get-AutomationEvidencePackages $ExpectedContent
    if ($RuntimeValidationOnly) {
      $lines = @($Output -split '\r?\n' | Where-Object { $_.StartsWith('{', [StringComparison]::Ordinal) })
      if ($lines.Count -ne 1 -or $Output.Contains('MAESTER_ASSESSMENT_RECEIPT_V1:')) { throw 'runtime receipt missing or ambiguous' }
      $r = ConvertFrom-MaesterReceiptJson $lines[0]
      Assert-EvidenceObject $r @('Kind','SchemaVersion','PowerShellVersion','DotNetVersion','Modules')
      Assert-EvidenceStrings $r @('Kind','PowerShellVersion','DotNetVersion')
      if ($r.Kind -cne 'Maester.RuntimeValidation' -or (Get-EvidenceCount $r.SchemaVersion) -ne 1) { throw 'runtime kind' }
      Assert-AutomationEvidenceRuntime $r.PowerShellVersion $r.DotNetVersion
      if ($r.Modules -isnot [array] -or $r.Modules.Count -ne 7) { throw 'runtime modules' }
      $modules = @{}
      foreach ($module in $r.Modules) {
        Assert-EvidenceObject $module @('Name','Version','Path','ModuleBase')
        Assert-EvidenceStrings $module @('Name','Version','Path','ModuleBase')
        if ($modules.ContainsKey($module.Name) -or $module.Name -cnotin @('NuGet','PackageManagement','PowerShellGet','Az.Accounts','Microsoft.Graph.Authentication','Pester','Maester') -or
            $module.Version -cne $packages[$module.Name]) { throw 'runtime module mismatch' }
        $modules[$module.Name] = $module.Version
      }
      return [ordered]@{ Scope = 'RuntimeImportsOnly'; MailDeliveryVerified = $false; WorkloadCoverageVerified = $false; RunbookSha256 = $source; Runtime = @{ PowerShell = $r.PowerShellVersion; DotNet = $r.DotNetVersion; Modules = $modules } }
    }
    $prefix = 'MAESTER_ASSESSMENT_RECEIPT_V1:'
    if ([regex]::Matches($Output, [regex]::Escape($prefix)).Count -ne 1) { throw 'missing or duplicate receipt' }
    $lines = @($Output -split '\r?\n' | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) })
    if ($lines.Count -ne 1) { throw 'receipt framing' }
    $r = Assert-AutomationAssessmentReceipt -Json $lines[0].Substring($prefix.Length) -JobId $JobId -Packages $packages -NotBefore $NotBefore -RequireNoMail:$RequireNoMail -ExpectWebApp:$ExpectWebApp -ExpectExchangeImport:$ExpectExchangeImport -ExpectTeamsImport:$ExpectTeamsImport
    [ordered]@{ Scope = $(if ($RequireNoMail) { 'NoMailAssessmentHealthAndPublication' } else { 'AssessmentHealthAndPublication' }); MailDeliveryVerified = $false; WorkloadCoverageVerified = $false; RunbookSha256 = $source; Receipt = $r }
  }
  catch { throw 'validation.jobEvidenceInvalidOrMismatched' }
}

Export-ModuleMember -Function Get-AutomationEvidenceSource, Get-AutomationEvidencePackages, Assert-AutomationAssessmentReceipt, Read-AutomationJobEvidence
