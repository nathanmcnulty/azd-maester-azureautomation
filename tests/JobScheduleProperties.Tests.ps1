BeforeAll {
  . (Join-Path $PSScriptRoot '../scripts/JobScheduleOwnership.ps1')
  function New-JobScheduleProperties {
    param([string]$ParametersJson = 'null', [switch]$Dictionary)
    $properties = @'
{
  "jobScheduleId": "22222222-2222-4222-8222-222222222222",
  "runbook": { "name": "maester-runbook" },
  "schedule": { "name": "maester-weekly-sunday" },
  "runOn": null
}
'@
    if ($ParametersJson -ne 'missing') { $properties = $properties.TrimEnd().TrimEnd('}') + ',"parameters":' + $ParametersJson + '}' }
    if ($Dictionary) { return ($properties | ConvertFrom-Json -AsHashtable) }
    return ($properties | ConvertFrom-Json)
  }
}

Describe 'Azure Automation association property comparison' {
  It 'equates only outer parameters null and empty object for <Shape> without changing either raw record' -ForEach @(
    @{ Shape = 'JSON PSCustomObject'; Dictionary = $false },
    @{ Shape = 'JSON dictionary'; Dictionary = $true }
  ) {
    Set-StrictMode -Version Latest
    $list = New-JobScheduleProperties -ParametersJson 'null' -Dictionary:$Dictionary
    $exact = New-JobScheduleProperties -ParametersJson '{}' -Dictionary:$Dictionary
    $beforeList = $list | ConvertTo-Json -Depth 100 -Compress
    $beforeExact = $exact | ConvertTo-Json -Depth 100 -Compress

    $listJson = ConvertTo-MaesterJobSchedulePropertiesJson -Properties $list
    $exactJson = ConvertTo-MaesterJobSchedulePropertiesJson -Properties $exact

    $listJson | Should -BeExactly $exactJson
    (ConvertTo-MaesterJobSchedulePropertiesJson -Properties $exact) | Should -BeExactly $listJson
    ($list | ConvertTo-Json -Depth 100 -Compress) | Should -BeExactly $beforeList
    ($exact | ConvertTo-Json -Depth 100 -Compress) | Should -BeExactly $beforeExact
    $listJson | Should -Match '"parameters":\{\}'
    $listJson | Should -Match '"runOn":null'
  }

  It 'retains parameter property presence independently of null/empty equivalence: <Left> versus <Right>' -ForEach @(
    @{ Left = 'missing'; Right = 'null' }, @{ Left = 'null'; Right = 'missing' },
    @{ Left = 'missing'; Right = '{}' }, @{ Left = '{}'; Right = 'missing' }
  ) {
    foreach ($dictionary in @($false, $true)) {
      $leftProperties = New-JobScheduleProperties -ParametersJson $Left -Dictionary:$dictionary
      $rightProperties = New-JobScheduleProperties -ParametersJson $Right -Dictionary:$dictionary
      (ConvertTo-MaesterJobSchedulePropertiesJson -Properties $leftProperties) | Should -Not -BeExactly (ConvertTo-MaesterJobSchedulePropertiesJson -Properties $rightProperties)
    }
  }

  It 'leaves a missing parameter property absent' {
    foreach ($dictionary in @($false, $true)) {
      $properties = New-JobScheduleProperties -ParametersJson 'missing' -Dictionary:$dictionary
      $before = $properties | ConvertTo-Json -Depth 100 -Compress
      $json = ConvertTo-MaesterJobSchedulePropertiesJson -Properties $properties
      $json | Should -Not -Match '"parameters"'
      $json | Should -BeExactly (ConvertTo-MaesterCanonicalJson $properties)
      ($properties | ConvertTo-Json -Depth 100 -Compress) | Should -BeExactly $before
    }
  }

  It 'preserves complete nonempty parameters and runOn while ignoring object key order' {
    Set-StrictMode -Version Latest
    $properties = New-JobScheduleProperties -ParametersJson '{"IncludeAzure":"false","ExistingParameter":"retained","Nested":{"Null":null,"False":false,"Zero":0,"Empty":"","Array":[null,0,false,"x"]}}'
    $properties.runOn = 'existing-hybrid-worker'
    $reordered = @'
{"parameters":{"Nested":{"Array":[null,0,false,"x"],"Empty":"","Zero":0,"False":false,"Null":null},"ExistingParameter":"retained","IncludeAzure":"false"},"schedule":{"name":"maester-weekly-sunday"},"runbook":{"name":"maester-runbook"},"runOn":"existing-hybrid-worker","jobScheduleId":"22222222-2222-4222-8222-222222222222"}
'@ | ConvertFrom-Json -AsHashtable
    $before = $properties | ConvertTo-Json -Depth 100 -Compress
    $json = ConvertTo-MaesterJobSchedulePropertiesJson -Properties $properties
    $json | Should -BeExactly (ConvertTo-MaesterCanonicalJson $properties)
    $json | Should -BeExactly (ConvertTo-MaesterJobSchedulePropertiesJson -Properties $reordered)
    $json | Should -Match '"Array":\[null,0,false,"x"\]'
    $json | Should -Match '"Null":null'
    $json | Should -Match '"False":false'
    $json | Should -Match '"Zero":0'
    $json | Should -Match '"runOn":"existing-hybrid-worker"'
    ($properties | ConvertTo-Json -Depth 100 -Compress) | Should -BeExactly $before
  }

  It 'retains <Problem> as a real parameter difference' -ForEach @(
    @{ Problem = 'nonempty loss to empty'; Left = '{"ExistingParameter":"retained"}'; Right = '{}' },
    @{ Problem = 'nonempty loss to null'; Left = '{"ExistingParameter":"retained"}'; Right = 'null' },
    @{ Problem = 'nonempty loss to missing'; Left = '{"ExistingParameter":"retained"}'; Right = 'missing' },
    @{ Problem = 'changed string'; Left = '{"ExistingParameter":"retained"}'; Right = '{"ExistingParameter":"changed"}' },
    @{ Problem = 'string case'; Left = '{"ExistingParameter":"retained"}'; Right = '{"ExistingParameter":"RETAINED"}' },
    @{ Problem = 'null-valued entry loss'; Left = '{"ExistingParameter":null}'; Right = '{}' },
    @{ Problem = 'nested null loss'; Left = '{"Config":{"Nested":null}}'; Right = '{"Config":{}}' },
    @{ Problem = 'nested null versus empty'; Left = '{"Config":{"Nested":null}}'; Right = '{"Config":{"Nested":""}}' },
    @{ Problem = 'nested null versus object'; Left = '{"Config":null}'; Right = '{"Config":{}}' },
    @{ Problem = 'boolean versus string'; Left = '{"Config":{"Nested":false}}'; Right = '{"Config":{"Nested":"false"}}' },
    @{ Problem = 'number versus string'; Left = '{"Config":{"Nested":1}}'; Right = '{"Config":{"Nested":"1"}}' },
    @{ Problem = 'array versus object'; Left = '{"Config":[]}'; Right = '{"Config":{}}' },
    @{ Problem = 'array null removal'; Left = '{"Config":[null,"x"]}'; Right = '{"Config":["x"]}' },
    @{ Problem = 'array order'; Left = '{"Config":["a","b"]}'; Right = '{"Config":["b","a"]}' }
  ) {
    foreach ($dictionary in @($false, $true)) {
      $leftProperties = New-JobScheduleProperties -ParametersJson $Left -Dictionary:$dictionary
      $rightProperties = New-JobScheduleProperties -ParametersJson $Right -Dictionary:$dictionary
      (ConvertTo-MaesterJobSchedulePropertiesJson -Properties $leftProperties) | Should -Not -BeExactly (ConvertTo-MaesterJobSchedulePropertiesJson -Properties $rightProperties)
    }
  }

  It 'fails closed on non-null <Json> parameters for both JSON representations' -ForEach @(
    @{ Json = '""' }, @{ Json = '"scalar"' }, @{ Json = 'true' }, @{ Json = 'false' },
    @{ Json = '0' }, @{ Json = '1' }, @{ Json = '[]' }, @{ Json = '[{}]' }, @{ Json = '[null]' }
  ) {
    foreach ($dictionary in @($false, $true)) {
      $properties = New-JobScheduleProperties -ParametersJson $Json -Dictionary:$dictionary
      $before = $properties | ConvertTo-Json -Depth 100 -Compress
      { ConvertTo-MaesterJobSchedulePropertiesJson -Properties $properties } | Should -Throw '*parameters*'
      ($properties | ConvertTo-Json -Depth 100 -Compress) | Should -BeExactly $before
    }
  }

  It 'retains every nonparameter association property difference: <Problem>' -ForEach @(
    @{ Problem = 'runOn null versus empty' }, @{ Problem = 'runOn null versus missing' },
    @{ Problem = 'runOn string versus null' }, @{ Problem = 'runOn array versus string' },
    @{ Problem = 'jobScheduleId' }, @{ Problem = 'runbook name' }, @{ Problem = 'schedule name' },
    @{ Problem = 'other property addition' }, @{ Problem = 'other property null versus missing' },
    @{ Problem = 'other nested null versus empty' }
  ) {
    $left = New-JobScheduleProperties -ParametersJson 'null'
    $right = New-JobScheduleProperties -ParametersJson '{}'
    switch ($Problem) {
      'runOn null versus empty' { $right.runOn = '' }
      'runOn null versus missing' { $right.PSObject.Properties.Remove('runOn') }
      'runOn string versus null' { $left.runOn = 'existing-hybrid-worker' }
      'runOn array versus string' { $left.runOn = @('existing-hybrid-worker'); $right.runOn = 'existing-hybrid-worker' }
      'jobScheduleId' { $right.jobScheduleId = '44444444-4444-4444-8444-444444444444' }
      'runbook name' { $right.runbook.name = 'another-runbook' }
      'schedule name' { $right.schedule.name = 'another-schedule' }
      'other property addition' { $right | Add-Member -NotePropertyName futureProperty -NotePropertyValue 'drift' }
      'other property null versus missing' { $left | Add-Member -NotePropertyName futureProperty -NotePropertyValue $null }
      'other nested null versus empty' {
        $left | Add-Member -NotePropertyName futureProperty -NotePropertyValue ([pscustomobject]@{ nested = $null })
        $right | Add-Member -NotePropertyName futureProperty -NotePropertyValue ([pscustomobject]@{})
      }
    }
    (ConvertTo-MaesterJobSchedulePropertiesJson -Properties $left) | Should -Not -BeExactly (ConvertTo-MaesterJobSchedulePropertiesJson -Properties $right)
  }

  It 'does not change generic schedule/runbook canonical JSON equivalence' {
    $nullParameters = New-JobScheduleProperties -ParametersJson 'null'
    $emptyParameters = New-JobScheduleProperties -ParametersJson '{}'
    (ConvertTo-MaesterCanonicalJson $nullParameters) | Should -Not -BeExactly (ConvertTo-MaesterCanonicalJson $emptyParameters)
  }
}
