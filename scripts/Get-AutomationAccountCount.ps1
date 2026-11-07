function Get-MaesterAutomationAccountCount {
  param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Location)
  # This is an Azure CLI core command: no implicit extension installation prompt.
  # resource list follows provider result pages before emitting its JSON array.
  $json = & az resource list --subscription $SubscriptionId --resource-type Microsoft.Automation/automationAccounts -o json --only-show-errors
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($json -join "`n"))) {
    throw 'Could not read Automation account inventory. Resolve the Azure CLI error before provisioning.'
  }
  try { $accounts = ConvertFrom-Json -InputObject ($json -join "`n") -NoEnumerate -ErrorAction Stop }
  catch { throw 'Automation account inventory was not a JSON array.' }
  if ($accounts -isnot [Collections.IList]) { throw 'Automation account inventory was not a JSON array.' }
  foreach ($account in $accounts) {
    if ($account.type -ine 'Microsoft.Automation/automationAccounts' -or
        -not $account.id.StartsWith("/subscriptions/$SubscriptionId/", [StringComparison]::OrdinalIgnoreCase) -or
        [string]::IsNullOrWhiteSpace([string]$account.location)) { throw 'Automation account inventory contained an unexpected resource.' }
  }
  @($accounts | Where-Object location -ieq $Location).Count
}
