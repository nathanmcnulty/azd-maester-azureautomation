function Test-MaesterGuid {
  param([string]$Value)
  $parsed = [guid]::Empty
  return [guid]::TryParse($Value, [ref]$parsed)
}

function Assert-MaesterJobScheduleIdentity {
  param(
    [Parameter(Mandatory)][string]$ExpectedAccountId,
    [Parameter(Mandatory)][string]$ExpectedJobScheduleId,
    [Parameter(Mandatory)]$JobSchedule
  )
  # Azure's GET/list examples omit name/type. The full ID and required GUID
  # establish identity; optional labels must agree if the service supplies them.
  $record = [pscustomobject]$JobSchedule
  $message = 'The Automation association readback does not match its exact ID, selected GUID, and any supplied name/type.'
  if (-not (Test-MaesterGuid -Value $ExpectedJobScheduleId) -or
      -not $record.PSObject.Properties['id'] -or $record.id -isnot [string] -or
      $record.id -ine "$ExpectedAccountId/jobSchedules/$ExpectedJobScheduleId" -or
      -not $record.PSObject.Properties['properties'] -or $null -eq $record.properties) { throw $message }
  $properties = [pscustomobject]$record.properties
  if (-not $properties.PSObject.Properties['jobScheduleId'] -or $properties.jobScheduleId -isnot [string] -or
      $properties.jobScheduleId -ine $ExpectedJobScheduleId -or
      ($record.PSObject.Properties['name'] -and ($record.name -isnot [string] -or $record.name -ine $ExpectedJobScheduleId)) -or
      ($record.PSObject.Properties['type'] -and ($record.type -isnot [string] -or $record.type -ine 'Microsoft.Automation/automationAccounts/jobSchedules'))) {
    throw $message
  }
}

function Assert-MaesterOwnershipReceiptTarget {
  param(
    [Parameter(Mandatory = $true)][string]$ExpectedAccountId,
    [Parameter(Mandatory = $true)][string]$ExpectedPrincipalId,
    [Parameter(Mandatory = $true)][string]$ExpectedJobScheduleId,
    [Parameter(Mandatory = $true)]$Account,
    [Parameter(Mandatory = $true)]$JobSchedule
  )
  Assert-MaesterJobScheduleIdentity -ExpectedAccountId $ExpectedAccountId -ExpectedJobScheduleId $ExpectedJobScheduleId -JobSchedule $JobSchedule
  if (-not (Test-MaesterGuid -Value $ExpectedJobScheduleId) -or
      [string]$Account.id -ine $ExpectedAccountId -or
      [string]$Account.identity.principalId -ine $ExpectedPrincipalId -or
      [string]$JobSchedule.properties.schedule.name -ine 'maester-weekly-sunday' -or
      [string]$JobSchedule.properties.runbook.name -ine 'maester-runbook') {
    throw 'Provisioned Automation account or jobSchedule does not match the template ownership receipt.'
  }
}

function Resolve-MaesterJobScheduleOwnership {
  param(
    [Parameter(Mandatory = $true)][string]$ExpectedAccountId,
    [AllowNull()]$Account,
    [AllowNull()][object[]]$JobSchedules = @(),
    [string]$ReceiptAccountId = '',
    [string]$ReceiptPrincipalId = '',
    [string]$ReceiptJobScheduleId = '',
    [string]$AdoptAccountId = '',
    [string]$AdoptPrincipalId = '',
    [string]$AdoptJobScheduleId = ''
  )

  if ($null -eq $Account) {
    $priorBinding = @(@($ReceiptAccountId, $ReceiptPrincipalId, $ReceiptJobScheduleId,
      $AdoptAccountId, $AdoptPrincipalId, $AdoptJobScheduleId) |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($priorBinding.Count -gt 0) {
      throw 'The prior Automation ownership receipt or adoption target has no matching live account; reconcile the exact target before redeployment.'
    }
    return [pscustomobject]@{ JobScheduleId = [guid]::NewGuid().ToString(); OwnedJobScheduleId = '' }
  }

  $liveAccountId = [string]$Account.id
  $livePrincipalId = [string]$Account.identity.principalId
  if ($liveAccountId -ine $ExpectedAccountId -or [string]::IsNullOrWhiteSpace($livePrincipalId)) {
    throw 'The live Automation account identity does not match the expected deployment target.'
  }

  $adoptParts = @(@($AdoptAccountId, $AdoptPrincipalId, $AdoptJobScheduleId) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($adoptParts.Count -gt 0 -and $adoptParts.Count -lt 3) { throw 'The explicit Automation adoption request is incomplete.' }
  if ($adoptParts.Count -eq 3 -and -not [string]::IsNullOrWhiteSpace($ReceiptAccountId) -and
      ($AdoptAccountId -ine $ReceiptAccountId -or $AdoptPrincipalId -ine $ReceiptPrincipalId -or $AdoptJobScheduleId -ine $ReceiptJobScheduleId)) {
    throw 'The explicit Automation adoption request conflicts with the ownership receipt.'
  }
  $hasReceipt = -not [string]::IsNullOrWhiteSpace($ReceiptAccountId)
  $receiptParts = @(@($ReceiptAccountId, $ReceiptPrincipalId, $ReceiptJobScheduleId) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($receiptParts.Count -gt 0 -and $receiptParts.Count -lt 3) {
    throw 'The saved Automation ownership receipt is incomplete.'
  }
  if ($hasReceipt) {
    if ($ReceiptAccountId -ine $liveAccountId -or $ReceiptPrincipalId -ine $livePrincipalId -or
        -not (Test-MaesterGuid -Value $ReceiptJobScheduleId)) {
      throw 'The saved Automation ownership receipt does not match the live account identity or has no valid jobSchedule ID.'
    }
    $selectedId = $ReceiptJobScheduleId
  }
  else {
    if ($AdoptAccountId -ine $liveAccountId -or $AdoptPrincipalId -ine $livePrincipalId) {
      throw 'Existing Automation account has no matching ownership receipt. Explicit adoption of its account ID and principal ID is required before redeployment.'
    }
    $selectedId = $AdoptJobScheduleId
  }

  $owned = @()
  foreach ($jobSchedule in @($JobSchedules)) {
    if ($null -eq $jobSchedule) { continue }
    $record = [pscustomobject]$jobSchedule
    $id = [string]$jobSchedule.properties.jobScheduleId
    $nameId = if ($record.PSObject.Properties['name']) { [string]$record.name } else { '' }
    if ($record.PSObject.Properties['name'] -and $nameId -ine $id) {
      throw 'A live jobSchedule has inconsistent name and jobScheduleId values.'
    }
    if (-not (Test-MaesterGuid -Value $id)) {
      throw 'A live jobSchedule has no valid GUID. Refusing to change an ambiguous account.'
    }
    if ($id -ieq $selectedId) {
      Assert-MaesterJobScheduleIdentity -ExpectedAccountId $ExpectedAccountId -ExpectedJobScheduleId $selectedId -JobSchedule $jobSchedule
    }
    $scheduleName = [string]$jobSchedule.properties.schedule.name
    $runbookName = [string]$jobSchedule.properties.runbook.name
    if ($scheduleName -ieq 'maester-weekly-sunday' -and $runbookName -ine 'maester-runbook') {
      throw 'The template schedule name is linked to an unexpected runbook.'
    }
    if ($id -ieq $selectedId -and ($scheduleName -ine 'maester-weekly-sunday' -or $runbookName -ine 'maester-runbook')) {
      throw 'The recorded jobSchedule ID now belongs to a different schedule or runbook.'
    }
    if ($scheduleName -ieq 'maester-weekly-sunday' -and $runbookName -ieq 'maester-runbook') {
      $owned += $id
    }
  }

  if ($owned.Count -gt 1) { throw 'More than one live template jobSchedule exists; explicit reconciliation is required.' }
  if ($owned.Count -eq 1 -and [string]::IsNullOrWhiteSpace($selectedId)) {
    throw 'A live template jobSchedule requires its exact ID for explicit adoption.'
  }
  if ($owned.Count -eq 1 -and $owned[0] -ine $selectedId) {
    throw 'The live template jobSchedule ID differs from the saved receipt or explicit adoption ID.'
  }
  if (-not [string]::IsNullOrWhiteSpace($selectedId) -and -not (Test-MaesterGuid -Value $selectedId)) {
    throw 'The adopted jobSchedule ID must be a GUID.'
  }
  if ($owned.Count -eq 0 -and $hasReceipt) {
    throw 'The receipt-bound Automation jobSchedule disappeared; reconcile the exact target before redeployment.'
  }
  if ($owned.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($AdoptJobScheduleId) -and -not $hasReceipt) {
    throw 'The explicit adoption jobSchedule ID was not found in the live account.'
  }

  return [pscustomobject]@{
    JobScheduleId = if ([string]::IsNullOrWhiteSpace($selectedId)) { [guid]::NewGuid().ToString() } else { $selectedId }
    OwnedJobScheduleId = if ($owned.Count -eq 1) { $owned[0] } else { '' }
  }
}

function Assert-MaesterJobScheduleWriteTarget {
  param(
    [Parameter(Mandatory = $true)][string]$ExpectedAccountId,
    [Parameter(Mandatory = $true)][string]$ExpectedPrincipalId,
    [Parameter(Mandatory = $true)][string]$JobScheduleId,
    [Parameter(Mandatory = $true)]$Account,
    [AllowNull()][object[]]$JobSchedules = @(),
    [string]$ReceiptAccountId = '',
    [string]$ReceiptPrincipalId = '',
    [string]$ReceiptJobScheduleId = '',
    [string]$AdoptAccountId = '',
    [string]$AdoptPrincipalId = '',
    [string]$AdoptJobScheduleId = ''
  )

  if (-not (Test-MaesterGuid -Value $JobScheduleId) -or
      [string]$Account.id -ine $ExpectedAccountId -or
      [string]$Account.identity.principalId -ine $ExpectedPrincipalId) {
    throw 'The selected jobSchedule or Automation account identity does not match the deployment target.'
  }
  $receiptParts = @(@($ReceiptAccountId, $ReceiptPrincipalId, $ReceiptJobScheduleId) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($receiptParts.Count -gt 0 -and $receiptParts.Count -lt 3) { throw 'The saved Automation ownership receipt is incomplete.' }
  if ($receiptParts.Count -eq 3 -and
      ($ReceiptAccountId -ine $ExpectedAccountId -or $ReceiptPrincipalId -ine $ExpectedPrincipalId -or $ReceiptJobScheduleId -ine $JobScheduleId)) {
    throw 'The saved Automation ownership receipt differs from the selected jobSchedule.'
  }
  $adoptParts = @(@($AdoptAccountId, $AdoptPrincipalId, $AdoptJobScheduleId) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($adoptParts.Count -gt 0 -and
      ($adoptParts.Count -ne 3 -or $AdoptAccountId -ine $ExpectedAccountId -or
       $AdoptPrincipalId -ine $ExpectedPrincipalId -or $AdoptJobScheduleId -ine $JobScheduleId)) {
    throw 'The explicit Automation adoption target differs from the selected jobSchedule.'
  }
  $matchingTemplateIds = @()
  foreach ($item in @($JobSchedules)) {
    if ($null -eq $item) { throw 'Automation jobSchedule inventory contains an empty record.' }
    $record = [pscustomobject]$item
    $id = [string]$item.properties.jobScheduleId
    if (-not (Test-MaesterGuid -Value $id) -or
        ($record.PSObject.Properties['name'] -and [string]$record.name -ine $id)) {
      throw 'Automation jobSchedule inventory contains an ambiguous ID.'
    }
    if ($id -ieq $JobScheduleId) {
      Assert-MaesterJobScheduleIdentity -ExpectedAccountId $ExpectedAccountId -ExpectedJobScheduleId $JobScheduleId -JobSchedule $item
    }
    $isTemplate = [string]$item.properties.schedule.name -ieq 'maester-weekly-sunday' -and
      [string]$item.properties.runbook.name -ieq 'maester-runbook'
    if ([string]$item.properties.schedule.name -ieq 'maester-weekly-sunday' -and -not $isTemplate) {
      throw 'The template schedule name is linked to an unexpected runbook.'
    }
    if ($id -ieq $JobScheduleId -and -not $isTemplate) {
      throw 'The selected jobSchedule ID belongs to another association.'
    }
    if ($isTemplate) { $matchingTemplateIds += $id }
  }
  if ($matchingTemplateIds.Count -gt 1 -or
      ($matchingTemplateIds.Count -eq 1 -and $matchingTemplateIds[0] -ine $JobScheduleId)) {
    throw 'The template jobSchedule association is ambiguous or differs from the selected ID.'
  }
  if ($matchingTemplateIds.Count -eq 0 -and ($receiptParts.Count -gt 0 -or $adoptParts.Count -gt 0)) {
    throw 'The receipt-bound or adopted Automation jobSchedule disappeared; explicit reconciliation is required.'
  }
  if ($matchingTemplateIds.Count -eq 1 -and $receiptParts.Count -eq 0 -and $adoptParts.Count -eq 0) {
    throw 'An existing template jobSchedule requires an ownership receipt or explicit adoption.'
  }
}


function Get-MaesterUpgradeBoolean {
  [CmdletBinding()]
  param([AllowEmptyString()][string]$Value, [Parameter(Mandatory)][string]$Name, [bool]$Default = $false)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
  if ($Value -in @('true', 'false')) { return $Value -ieq 'true' }
  throw "$Name must be true or false."
}

function Assert-MaesterCompleteInventory {
  [CmdletBinding()]
  param([AllowNull()]$Response, [Parameter(Mandatory)][string]$Name)
  if ($null -eq $Response -or -not $Response.PSObject.Properties['value'] -or
      $null -eq $Response.value -or $Response.value -isnot [System.Collections.IList] -or
      ($Response.PSObject.Properties['nextLink'] -and $Response.nextLink) -or
      @($Response.value | Where-Object { $null -eq $_ }).Count -gt 0) {
    throw "Automation $Name inventory was incomplete."
  }
}

function Assert-MaesterExistingAutomationResources {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedAccountId,
    [AllowNull()]$Account,
    [AllowNull()][object[]]$JobSchedules = @(),
    [AllowNull()][object[]]$Schedules = @(),
    [AllowNull()][object[]]$Runbooks = @(),
    [Parameter(Mandatory)]$Ownership,
    [switch]$RequireExisting
  )
  if ([string]::IsNullOrWhiteSpace([string]$Ownership.OwnedJobScheduleId)) {
    if ($RequireExisting) { throw 'Upgrade preservation requires a verified existing Automation ownership binding.' }
    return [pscustomobject]@{ Existing = $false; JobSchedule = $null; Schedule = $null; Runbook = $null }
  }
  if ($null -eq $Account -or [string]$Account.id -ine $ExpectedAccountId) {
    throw 'The existing Automation account disappeared or changed before preservation verification.'
  }
  $selected = @{}
  foreach ($spec in @(
      @{ Kind = 'JobSchedule'; Segment = 'jobSchedules'; Name = [string]$Ownership.OwnedJobScheduleId; Items = @($JobSchedules) },
      @{ Kind = 'Schedule'; Segment = 'schedules'; Name = 'maester-weekly-sunday'; Items = @($Schedules) },
      @{ Kind = 'Runbook'; Segment = 'runbooks'; Name = 'maester-runbook'; Items = @($Runbooks) }
    )) {
    $expectedId = "$ExpectedAccountId/$($spec.Segment)/$($spec.Name)"
    $items = @($spec.Items | Where-Object {
      $record = [pscustomobject]$_
      ($record.PSObject.Properties['name'] -and [string]$record.name -ieq $spec.Name) -or
      [string]$_.id -ieq $expectedId -or
      ($spec.Kind -eq 'JobSchedule' -and [string]$_.properties.jobScheduleId -ieq $spec.Name)
    })
    if ($items.Count -ne 1) {
      throw "The verified existing Automation $($spec.Kind) disappeared, changed identity, or is ambiguous."
    }
    if ($spec.Kind -eq 'JobSchedule') {
      Assert-MaesterJobScheduleIdentity -ExpectedAccountId $ExpectedAccountId -ExpectedJobScheduleId $spec.Name -JobSchedule $items[0]
    }
    elseif ([string]$items[0].id -ine $expectedId -or
        [string]$items[0].name -ine $spec.Name -or
        [string]$items[0].type -ine "Microsoft.Automation/automationAccounts/$($spec.Segment)") {
      throw "The verified existing Automation $($spec.Kind) disappeared, changed identity, or is ambiguous."
    }
    $selected[$spec.Kind] = $items[0]
  }
  Assert-MaesterOwnershipReceiptTarget -ExpectedAccountId $ExpectedAccountId -ExpectedPrincipalId ([string]$Account.identity.principalId) `
    -ExpectedJobScheduleId ([string]$Ownership.JobScheduleId) -Account $Account -JobSchedule $selected.JobSchedule
  if ([string]$selected.Runbook.properties.runbookType -ine 'PowerShell') {
    throw 'The verified existing Automation runbook type is not PowerShell; reconcile it before upgrade.'
  }
  if ([string]$selected.Runbook.properties.state -ine 'Published') {
    throw 'The verified existing Automation runbook is not published; reconcile it before upgrade.'
  }
  return [pscustomobject]@{ Existing = $true; JobSchedule = $selected.JobSchedule; Schedule = $selected.Schedule; Runbook = $selected.Runbook }
}

function Get-MaesterRunbookPreservationMetadata {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ExpectedAccountId,
    [Parameter(Mandatory)][System.Collections.IDictionary]$Runbook
  )

  $expectedId = "$ExpectedAccountId/runbooks/maester-runbook"
  $properties = $Runbook['properties']
  if ([string]$Runbook['id'] -ine $expectedId -or [string]$Runbook['name'] -ine 'maester-runbook' -or
      [string]$Runbook['type'] -ine 'Microsoft.Automation/automationAccounts/runbooks' -or
      $properties -isnot [System.Collections.IDictionary] -or
      [string]$properties['state'] -ine 'Published' -or [string]$properties['runbookType'] -ine 'PowerShell') {
    throw 'The fresh runbook metadata read does not match the exact published PowerShell target.'
  }
  if ($Runbook['location'] -isnot [string] -or [string]::IsNullOrWhiteSpace($Runbook['location'])) {
    throw 'The fresh runbook metadata has no valid location.'
  }

  # Snapshot mutable metadata for comparison; content/state/runtime are checked
  # separately. Draft, parameters, timestamps and read-only fields are never replayed.
  $metadata = [ordered]@{ location = $Runbook['location']; properties = [ordered]@{} }
  foreach ($name in @('description', 'logProgress', 'logVerbose', 'logActivityTrace')) {
    if (-not $properties.Contains($name)) { continue }
    $value = $properties[$name]
    $valid = switch ($name) {
      'description' { $value -is [string] }
      'logProgress' { $value -is [bool] }
      'logVerbose' { $value -is [bool] }
      'logActivityTrace' { ($value -is [int] -or $value -is [long]) -and $value -ge [int]::MinValue -and $value -le [int]::MaxValue }
    }
    if (-not $valid) { throw "The fresh runbook metadata property '$name' has an unsupported null or value type." }
    $metadata.properties[$name] = $value
  }
  if ($Runbook.Contains('tags')) {
    if ($null -eq $Runbook['tags']) {
      # ARM treats null resource properties as absent: retain the untagged state.
      $metadata['tags'] = $null
      return $metadata
    }
    if ($Runbook['tags'] -isnot [System.Collections.IDictionary]) {
      throw 'The fresh runbook metadata tags must be a string-valued object.'
    }
    $metadata.tags = [ordered]@{}
    foreach ($key in $Runbook['tags'].Keys) {
      if ($key -isnot [string] -or $Runbook['tags'][$key] -isnot [string]) {
        throw 'The fresh runbook metadata tags must be a string-valued object.'
      }
      $metadata.tags[$key] = $Runbook['tags'][$key]
    }
  }
  return $metadata
}

function ConvertTo-MaesterCanonicalJson {
  param([AllowNull()]$Value)
  function ConvertTo-CanonicalValue {
    param([AllowNull()]$Item)
    if ($null -eq $Item) { return $null }
    if ($Item -is [System.Collections.IDictionary]) {
      $ordered = [ordered]@{}
      foreach ($key in @($Item.Keys | Sort-Object)) { $ordered[$key] = ConvertTo-CanonicalValue $Item[$key] }
      return $ordered
    }
    if ($Item -is [pscustomobject]) {
      $ordered = [ordered]@{}
      foreach ($property in @($Item.PSObject.Properties | Sort-Object Name)) { $ordered[$property.Name] = ConvertTo-CanonicalValue $property.Value }
      return $ordered
    }
    if ($Item -is [System.Collections.IList]) {
      $items = @(foreach ($element in $Item) { ConvertTo-CanonicalValue $element })
      return ,$items
    }
    return $Item
  }
  return ConvertTo-Json -InputObject (ConvertTo-CanonicalValue $Value) -Depth 100 -Compress
}

function Update-MaesterExistingRunbookRuntime {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ExpectedAccountId,
    [Parameter(Mandatory)]$ExpectedRuntimeName,
    [Parameter(Mandatory)]$ExpectedRuntimeVersion,
    [Parameter(Mandatory)][string]$ExpectedContent,
    [Parameter(Mandatory)][scriptblock]$GetResource,
    [Parameter(Mandatory)][scriptblock]$GetContent,
    [Parameter(Mandatory)][scriptblock]$PatchResource
  )

  # These selected-environment outputs come from the declared runtime resource,
  # never from an ambient override or the runbook's current binding.
  if ($ExpectedRuntimeName -isnot [string] -or $ExpectedRuntimeVersion -isnot [string] -or
      $ExpectedRuntimeVersion -cnotmatch '^[0-9]+\.[0-9]+$' -or
      $ExpectedRuntimeName -cne "PowerShell-$($ExpectedRuntimeVersion.Replace('.', ''))-Maester") {
    throw 'The deployment runtime name/version outputs are missing or inconsistent.'
  }
  $runtimeId = "$ExpectedAccountId/runtimeEnvironments/$ExpectedRuntimeName"
  $runtime = & $GetResource "$runtimeId`?api-version=2024-10-23"
  $runtimeRecord = $runtime | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
  $runtimeProperties = if ($runtimeRecord -is [System.Collections.IDictionary]) { $runtimeRecord['properties'] } else { $null }
  $definition = if ($runtimeProperties -is [System.Collections.IDictionary]) { $runtimeProperties['runtime'] } else { $null }
  if ($definition -isnot [System.Collections.IDictionary] -or
      [string]$runtimeRecord['id'] -ine $runtimeId -or [string]$runtimeRecord['name'] -ine $ExpectedRuntimeName -or
      [string]$runtimeRecord['type'] -ine 'Microsoft.Automation/automationAccounts/runtimeEnvironments' -or
      $definition['language'] -isnot [string] -or $definition['language'] -cne 'PowerShell' -or
      $definition['version'] -isnot [string] -or $definition['version'] -cne $ExpectedRuntimeVersion) {
    throw 'The exact deployment runtime does not match its account, name, type, language, and version.'
  }

  $runbookPath = "$ExpectedAccountId/runbooks/maester-runbook?api-version=2024-10-23"
  $contentPath = "$ExpectedAccountId/runbooks/maester-runbook/content?api-version=2024-10-23"
  $before = & $GetResource $runbookPath
  $beforeRecord = $before | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
  $beforeMetadata = Get-MaesterRunbookPreservationMetadata -ExpectedAccountId $ExpectedAccountId -Runbook $beforeRecord
  $currentRuntime = $beforeRecord['properties']['runtimeEnvironment']
  if ($currentRuntime -isnot [string] -or [string]::IsNullOrWhiteSpace($currentRuntime)) {
    throw 'The existing runbook has no verified scalar runtime binding before PATCH.'
  }
  $expected = $ExpectedContent.TrimStart([char]0xFEFF).Replace("`r`n", "`n")
  $published = & $GetContent $contentPath
  if ($published -isnot [string] -or [string]::IsNullOrWhiteSpace($published) -or
      $published.TrimStart([char]0xFEFF).Replace("`r`n", "`n") -cne $expected) {
    throw 'Published/local runbook content differs before the runtime PATCH.'
  }
  if ($currentRuntime -ieq $ExpectedRuntimeName) {
    Write-Host "Existing runbook is already bound to '$ExpectedRuntimeName'; runtime PATCH was skipped."
    return $false
  }

  # Use the documented direct update route instead of create-or-update PUT.
  # Readback must prove preservation; never upload or publish a draft here.
  Write-Host "Updating existing runbook runtime '$currentRuntime' to '$ExpectedRuntimeName'."
  $body = @{ properties = @{ runtimeEnvironment = $ExpectedRuntimeName } } | ConvertTo-Json -Depth 3 -Compress
  & $PatchResource $runbookPath $body | Out-Null
  $after = & $GetResource $runbookPath
  $afterRecord = $after | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
  $afterMetadata = Get-MaesterRunbookPreservationMetadata -ExpectedAccountId $ExpectedAccountId -Runbook $afterRecord
  $afterContent = & $GetContent $contentPath
  if ($afterRecord['properties']['runtimeEnvironment'] -isnot [string] -or
      $afterRecord['properties']['runtimeEnvironment'] -ine $ExpectedRuntimeName -or
      (ConvertTo-MaesterCanonicalJson $afterMetadata) -cne (ConvertTo-MaesterCanonicalJson $beforeMetadata) -or
      $afterContent -isnot [string] -or
      $afterContent.TrimStart([char]0xFEFF).Replace("`r`n", "`n") -cne $expected) {
    throw 'The runtime PATCH did not preserve the published runbook content, metadata, and expected binding.'
  }
  Write-Host "Verified existing runbook runtime binding '$ExpectedRuntimeName' with published content and metadata unchanged."
  return $true
}
