param([string]$TestPath, [string]$ResultPath, [int]$MemberCount, [int]$EmergencyCount, [switch]$FilterMemberToOne)
$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion 6.2.0 -ErrorAction Stop
$global:whatIfFixtureUsers = @{
  Member = @(for ($i=0; $i -lt $MemberCount; $i++) { @{id="member-$i";userPrincipalName="member-$i@example.invalid"} })
  Admin = @()
  EmergencyAccess = @(for ($i=0; $i -lt $EmergencyCount; $i++) { @{id="emergency-$i";userPrincipalName="emergency-$i@example.invalid"} })
}
if ($FilterMemberToOne) {
  $global:whatIfFixtureUsers.Member = @(@{id='emergency-0';userPrincipalName='emergency-0@example.invalid'}, @{id='member-0';userPrincipalName='member-0@example.invalid'})
}
$global:whatIfFixtureCalls = [Collections.Generic.List[object]]::new()
function global:Get-MtLicenseInformation { param($Product) 'P1' }
function global:Get-MtUser { param($Count,$UserType) $global:whatIfFixtureUsers[$UserType] }
function global:Test-MtCaWIFBlockLegacyAuthentication {
  param($UserId)
  $global:whatIfFixtureCalls.Add(@{operation='legacy';userId=$UserId}); $true
}
function global:Test-MtConditionalAccessWhatIf {
  param($UserId,$IncludeApplications,$ClientAppType)
  $global:whatIfFixtureCalls.Add(@{operation='emergency';userId=$UserId;application=$IncludeApplications;client=$ClientAppType})
}
$config=New-PesterConfiguration
$config.Run.Path=$TestPath;$config.Run.PassThru=$true;$config.Output.Verbosity='None'
$result=Invoke-Pester -Configuration $config
@{passed=$result.PassedCount;failed=$result.FailedCount;skipped=$result.SkippedCount;containerErrors=$result.FailedContainersCount;containerMessages=@($result.Containers.ErrorRecord|ForEach-Object {$_.Exception.Message});blockErrors=$result.FailedBlocksCount;total=$result.TotalCount;names=@($result.Tests|ForEach-Object Name);calls=@($global:whatIfFixtureCalls.ToArray());failures=@($result.Tests|Where-Object Result -eq Failed|ForEach-Object {@{name=$_.Name;messages=@($_.ErrorRecord|ForEach-Object {$_.Exception.Message})}})}|
  ConvertTo-Json -Depth 10|Set-Content -LiteralPath $ResultPath -Encoding utf8NoBOM
