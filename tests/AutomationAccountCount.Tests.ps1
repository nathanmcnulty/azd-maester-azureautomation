BeforeAll {
  . (Join-Path $PSScriptRoot '../scripts/Get-AutomationAccountCount.ps1')
  $subscription='11111111-1111-1111-1111-111111111111'
  function az {
    $global:accountCountCalls+=,($args -join ' ')
    $global:LASTEXITCODE=$global:accountCountExit
    $global:accountCountJson
  }
  function New-Account([string]$Name,[string]$Region) {
    @{id="/subscriptions/$subscription/resourceGroups/rg/providers/Microsoft.Automation/automationAccounts/$Name";type='Microsoft.Automation/automationAccounts';location=$Region}
  }
}
Describe 'Extension-free regional Automation inventory' {
  BeforeEach { $global:accountCountCalls=@();$global:accountCountExit=0;$global:accountCountJson='[]' }
  It 'uses only the core resource list command and counts matching regions' {
    $global:accountCountJson=@((New-Account a westus),(New-Account b eastus),(New-Account c WestUS))|ConvertTo-Json
    Get-MaesterAutomationAccountCount $subscription westus|Should -Be 2
    $global:accountCountCalls|Should -Be @("resource list --subscription $subscription --resource-type Microsoft.Automation/automationAccounts -o json --only-show-errors")
  }
  It 'accepts an empty complete array' { Get-MaesterAutomationAccountCount $subscription westus|Should -Be 0 }
  It 'does not infer an upper quota from ten or more accounts' {
    $global:accountCountJson=@(0..11|ForEach-Object {New-Account "a$_" westus})|ConvertTo-Json
    Get-MaesterAutomationAccountCount $subscription westus|Should -Be 12
  }
  It 'blocks provisioning when the CLI read fails' {
    $global:accountCountExit=1
    {Get-MaesterAutomationAccountCount $subscription westus}|Should -Throw '*Could not read*'
  }
  It 'rejects empty, malformed or non-array output' -ForEach @('', 'invalid', '{}', 'null') {
    $global:accountCountJson=$_
    {Get-MaesterAutomationAccountCount $subscription westus}|Should -Throw
  }
  It 'rejects resources outside the selected subscription or resource type' -ForEach @('subscription','type','location') {
    $row=New-Account a westus
    switch($_){'subscription'{$row.id=$row.id.Replace($subscription,'22222222-2222-2222-2222-222222222222')};'type'{$row.type='Microsoft.Storage/storageAccounts'};'location'{$row.location=''}}
    $global:accountCountJson=ConvertTo-Json -InputObject @($row)
    {Get-MaesterAutomationAccountCount $subscription westus}|Should -Throw '*unexpected resource*'
  }
}
AfterAll {Remove-Variable accountCountCalls,accountCountExit,accountCountJson -Scope Global -ErrorAction SilentlyContinue}
