BeforeAll {
  . (Join-Path $PSScriptRoot '../scripts/JobScheduleOwnership.ps1')
  function New-RuntimePatchFixture {
    param([string]$Version = '7.4')
    $accountId = '/subscriptions/sub-test/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-test'
    $runtimeName = "PowerShell-$($Version.Replace('.', ''))-Maester"
    # Use deserialized ARM JSON rather than synthetic hashtables. False, zero,
    # null, missing fields and escaped text must retain their service types.
    $runbook = @'
{
  "id": "/subscriptions/sub-test/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-test/runbooks/maester-runbook",
  "name": "maester-runbook", "type": "Microsoft.Automation/automationAccounts/runbooks", "location": "West US 2",
  "tags": { "Owner": "Custom 'quoted' Δ", "Interpolation": "${MUST_STAY_LITERAL}", "Empty": "" },
  "properties": {
    "state": "Published", "runbookType": "PowerShell", "runtimeEnvironment": "PowerShell-72-Existing",
    "description": "Preserve \"quotes\", 'apostrophes', Δ, a newline\nand ${MUST_STAY_LITERAL}",
    "logProgress": false, "logVerbose": true, "logActivityTrace": 0,
    "publishContentLink": { "uri": "https://example.invalid/never-replay" },
    "draft": { "inEdit": false }, "parameters": { "ExistingParameter": { "type": "String", "isMandatory": false } },
    "outputTypes": ["String"], "creationTime": "2020-01-01T00:00:00Z", "lastModifiedTime": "2020-02-01T00:00:00Z",
    "jobCount": 3, "provisioningState": "Succeeded"
  },
  "etag": "response-only", "systemData": { "createdBy": "response-only" }
}
'@ | ConvertFrom-Json
    $runtime = @'
{"type":"Microsoft.Automation/automationAccounts/runtimeEnvironments","location":"westus2","properties":{"runtime":{"language":"PowerShell","version":"7.4"},"provisioningState":"Succeeded"}}
'@ | ConvertFrom-Json
    $runtime | Add-Member -NotePropertyName id -NotePropertyValue "$accountId/runtimeEnvironments/$runtimeName"
    $runtime | Add-Member -NotePropertyName name -NotePropertyValue $runtimeName
    $runtime.properties.runtime.version = $Version
    $content = "# locally maintained runbook`nWrite-Output 'local Δ'`n"
    $global:runtimePatchFixture = @{
      AccountId = $accountId; RuntimeName = $runtimeName; RuntimeVersion = $Version; Runbook = $runbook; Runtime = $runtime
      ExpectedContent = $content; PublishedContent = $content; FailPatch = ''; AfterPatch = $null
      Calls = [Collections.Generic.List[string]]::new(); Bodies = [Collections.Generic.List[string]]::new(); PatchAttempts = 0
    }
  }
  function Invoke-RuntimePatchFixture {
    $fixture = $global:runtimePatchFixture
    Update-MaesterExistingRunbookRuntime -ExpectedAccountId $fixture.AccountId `
      -ExpectedRuntimeName $fixture.RuntimeName -ExpectedRuntimeVersion $fixture.RuntimeVersion `
      -ExpectedContent $fixture.ExpectedContent -GetResource {
        param($path)
        $fixture = $global:runtimePatchFixture
        $fixture.Calls.Add("GET $path")
        switch ($path -replace '\?.*$', '') {
          "$($fixture.AccountId)/runtimeEnvironments/$($fixture.RuntimeName)" { return ($fixture.Runtime | ConvertTo-Json -Depth 30 | ConvertFrom-Json) }
          "$($fixture.AccountId)/runbooks/maester-runbook" { return ($fixture.Runbook | ConvertTo-Json -Depth 30 | ConvertFrom-Json) }
          default { throw "Unexpected resource GET: $path" }
        }
      } -GetContent {
        param($path)
        $fixture = $global:runtimePatchFixture
        $fixture.Calls.Add("CONTENT GET $path")
        ($path -replace '\?.*$', '') | Should -BeExactly "$($fixture.AccountId)/runbooks/maester-runbook/content"
        return $fixture.PublishedContent
      } -PatchResource {
        param($path, $jsonBody)
        $fixture = $global:runtimePatchFixture
        $fixture.Calls.Add("PATCH $path")
        $fixture.Bodies.Add([string]$jsonBody)
        $fixture.PatchAttempts++
        ($path -replace '\?.*$', '') | Should -BeExactly "$($fixture.AccountId)/runbooks/maester-runbook"
        if ($fixture.FailPatch -eq 'before apply') { throw 'simulated runtime PATCH failure before apply' }
        $fixture.Runbook.properties.runtimeEnvironment = ($jsonBody | ConvertFrom-Json).properties.runtimeEnvironment
        if ($fixture.AfterPatch) { & $fixture.AfterPatch $fixture }
        if ($fixture.FailPatch -eq 'after apply') { throw 'simulated runtime PATCH response failure after apply' }
        # Response bodies are not verification. The helper must issue a fresh GET.
        return ($fixture.Runbook | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
      }
  }
  function Assert-RuntimePatchOnly {
    $fixture = $global:runtimePatchFixture
    $fixture.Bodies.Count | Should -Be 1
    $body = $fixture.Bodies[0] | ConvertFrom-Json
    @($body.PSObject.Properties.Name) | Should -Be @('properties')
    @($body.properties.PSObject.Properties.Name) | Should -Be @('runtimeEnvironment')
    $body.properties.runtimeEnvironment | Should -BeExactly $fixture.RuntimeName
    $fixture.Bodies[0] | Should -Not -Match 'location|tags|description|logProgress|logVerbose|logActivityTrace|runbookType|publishContentLink|draft|parameters|outputTypes|creationTime|lastModifiedTime|jobCount|provisioningState|etag|systemData'
  }
}

Describe 'Existing runbook runtime-only PATCH' {
  BeforeEach { New-RuntimePatchFixture }

  It 'binds PowerShell <Version> by one exact PATCH and preserves raw metadata and content' -ForEach @(
    @{ Version = '7.4' }, @{ Version = '7.6' }
  ) {
    New-RuntimePatchFixture -Version $Version
    $fixture = $global:runtimePatchFixture
    $before = $fixture.Runbook | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $before.properties.runtimeEnvironment = $fixture.RuntimeName
    $content = $fixture.PublishedContent
    $runtime = $fixture.Runtime | ConvertTo-Json -Depth 30 -Compress

    Invoke-RuntimePatchFixture | Should -BeTrue

    Assert-RuntimePatchOnly
    ($fixture.Runbook | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly ($before | ConvertTo-Json -Depth 30 -Compress)
    $fixture.PublishedContent | Should -BeExactly $content
    ($fixture.Runtime | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $runtime
    $fixture.Calls | Should -Contain "GET $($fixture.Runtime.id)?api-version=2024-10-23"
    @($fixture.Calls | Where-Object { $_ -eq "GET $($fixture.Runbook.id)?api-version=2024-10-23" }).Count | Should -BeGreaterOrEqual 2
    @($fixture.Calls | Where-Object { $_ -like 'CONTENT GET *' }).Count | Should -BeGreaterOrEqual 2
    ($fixture.Calls -join '|') | Should -Not -Match 'PUT |POST |DELETE |draft|publish\?|/jobs|jobSchedules|roleAssignments|graph.microsoft.com'
  }

  It 'skips PATCH after verifying an already bound PowerShell <Version> runbook on repeated calls' -ForEach @(
    @{ Version = '7.4' }, @{ Version = '7.6' }
  ) {
    New-RuntimePatchFixture -Version $Version
    $fixture = $global:runtimePatchFixture
    $fixture.Runbook.properties.runtimeEnvironment = $fixture.RuntimeName
    $before = $fixture.Runbook | ConvertTo-Json -Depth 30 -Compress
    Invoke-RuntimePatchFixture | Should -BeFalse
    Invoke-RuntimePatchFixture | Should -BeFalse
    $fixture.PatchAttempts | Should -Be 0
    ($fixture.Runbook | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
    @($fixture.Calls | Where-Object { $_ -like 'CONTENT GET *' }).Count | Should -BeGreaterOrEqual 2
  }

  It 'accepts only the existing BOM and CRLF normalization, retaining published bytes' {
    $fixture = $global:runtimePatchFixture
    $fixture.PublishedContent = [string][char]0xFEFF + $fixture.ExpectedContent.Replace("`n", "`r`n")
    $before = $fixture.PublishedContent
    Invoke-RuntimePatchFixture | Should -BeTrue
    $fixture.PublishedContent | Should -BeExactly $before
    Assert-RuntimePatchOnly
  }

  It 'preserves <Shape> metadata without inventing defaults' -ForEach @(
    @{ Shape = 'missing optional fields' }, @{ Shape = 'null tags' }, @{ Shape = 'empty tags' }, @{ Shape = 'empty description' }
  ) {
    $fixture = $global:runtimePatchFixture
    switch ($Shape) {
      'missing optional fields' {
        foreach ($name in @('description', 'logProgress', 'logVerbose', 'logActivityTrace')) { $fixture.Runbook.properties.PSObject.Properties.Remove($name) }
        $fixture.Runbook.PSObject.Properties.Remove('tags')
      }
      'null tags' { $fixture.Runbook.tags = $null }
      'empty tags' { $fixture.Runbook.tags = [pscustomobject]@{} }
      'empty description' { $fixture.Runbook.properties.description = '' }
    }
    $before = $fixture.Runbook | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $before.properties.runtimeEnvironment = $fixture.RuntimeName
    Invoke-RuntimePatchFixture | Should -BeTrue
    ($fixture.Runbook | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly ($before | ConvertTo-Json -Depth 30 -Compress)
    Assert-RuntimePatchOnly
  }

  It 'rejects preexisting <Problem> before PATCH, without publishing or attempting Edit recovery' -ForEach @(
    @{ Problem = 'Edit state' }, @{ Problem = 'wrong runbook ID' }, @{ Problem = 'wrong runbook name' },
    @{ Problem = 'wrong runbook type' }, @{ Problem = 'non PowerShell language' }, @{ Problem = 'missing location' },
    @{ Problem = 'changed content' }, @{ Problem = 'trailing content whitespace' }
  ) {
    $fixture = $global:runtimePatchFixture
    switch ($Problem) {
      'Edit state' { $fixture.Runbook.properties.state = 'Edit' }
      'wrong runbook ID' { $fixture.Runbook.id = $fixture.Runbook.id.Replace('/aa-test/', '/wrong-account/') }
      'wrong runbook name' { $fixture.Runbook.name = 'other-runbook' }
      'wrong runbook type' { $fixture.Runbook.type = 'Microsoft.Web/sites' }
      'non PowerShell language' { $fixture.Runbook.properties.runbookType = 'Python3' }
      'missing location' { $fixture.Runbook.PSObject.Properties.Remove('location') }
      'changed content' { $fixture.PublishedContent = "# edited`n" + $fixture.PublishedContent }
      'trailing content whitespace' { $fixture.PublishedContent += ' ' }
    }
    $before = $fixture.Runbook | ConvertTo-Json -Depth 30 -Compress
    { Invoke-RuntimePatchFixture } | Should -Throw
    $fixture.PatchAttempts | Should -Be 0
    ($fixture.Runbook | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
    ($fixture.Calls -join '|') | Should -Not -Match 'PATCH |PUT |POST |DELETE '
  }

  It 'rejects a <Shape> current runtime binding before PATCH' -ForEach @(
    @{ Shape = 'missing' }, @{ Shape = 'null' }, @{ Shape = 'blank' },
    @{ Shape = 'whitespace' }, @{ Shape = 'array' }, @{ Shape = 'number' }
  ) {
    $fixture = $global:runtimePatchFixture
    switch ($Shape) {
      'missing' { $fixture.Runbook.properties.PSObject.Properties.Remove('runtimeEnvironment') }
      'null' { $fixture.Runbook.properties.runtimeEnvironment = $null }
      'blank' { $fixture.Runbook.properties.runtimeEnvironment = '' }
      'whitespace' { $fixture.Runbook.properties.runtimeEnvironment = '   ' }
      'array' { $fixture.Runbook.properties.runtimeEnvironment = @('PowerShell-72-Existing') }
      'number' { $fixture.Runbook.properties.runtimeEnvironment = 74 }
    }
    { Invoke-RuntimePatchFixture } | Should -Throw '*verified scalar runtime binding before PATCH*'
    $fixture.PatchAttempts | Should -Be 0
    ($fixture.Calls -join '|') | Should -Not -Match 'PATCH |PUT |POST |DELETE '
  }

  It 'rejects target runtime <Problem> before PATCH' -ForEach @(
    @{ Problem = 'wrong full ID' }, @{ Problem = 'wrong name' }, @{ Problem = 'wrong type' },
    @{ Problem = 'wrong language' }, @{ Problem = 'wrong version' }, @{ Problem = 'missing runtime' },
    @{ Problem = 'numeric version' }
  ) {
    $fixture = $global:runtimePatchFixture
    switch ($Problem) {
      'wrong full ID' { $fixture.Runtime.id = $fixture.Runtime.id.Replace('/aa-test/', '/wrong-account/') }
      'wrong name' { $fixture.Runtime.name = 'PowerShell-76-Maester' }
      'wrong type' { $fixture.Runtime.type = 'Microsoft.Automation/automationAccounts/runbooks' }
      'wrong language' { $fixture.Runtime.properties.runtime.language = 'Python' }
      'wrong version' { $fixture.Runtime.properties.runtime.version = '7.6' }
      'missing runtime' { $fixture.Runtime.properties.PSObject.Properties.Remove('runtime') }
      'numeric version' { $fixture.Runtime.properties.runtime.version = 7.4 }
    }
    { Invoke-RuntimePatchFixture } | Should -Throw
    $fixture.PatchAttempts | Should -Be 0
    ($fixture.Calls -join '|') | Should -Not -Match 'PATCH |PUT |POST |DELETE '
  }

  It 'rejects unsafe or inconsistent deployed runtime outputs: <Problem>' -ForEach @(
    @{ Problem = 'mismatched name'; Name = 'PowerShell-76-Maester'; Version = '7.4' },
    @{ Problem = 'blank name'; Name = ''; Version = '7.4' },
    @{ Problem = 'path injection'; Name = '../PowerShell-74-Maester'; Version = '7.4' },
    @{ Problem = 'query injection'; Name = 'PowerShell-74-Maester?x=1'; Version = '7.4' },
    @{ Problem = 'name whitespace'; Name = ' PowerShell-74-Maester'; Version = '7.4' },
    @{ Problem = 'version whitespace'; Name = 'PowerShell-74-Maester'; Version = '7.4 ' },
    @{ Problem = 'non-numeric version'; Name = 'PowerShell-74-Maester'; Version = 'current' }
  ) {
    $fixture = $global:runtimePatchFixture
    $fixture.RuntimeName = $Name; $fixture.RuntimeVersion = $Version
    { Invoke-RuntimePatchFixture } | Should -Throw
    $fixture.PatchAttempts | Should -Be 0
    $fixture.Calls.Count | Should -Be 0
  }

  It 'fails strict verification when PATCH changes <Problem>, without a recovery write' -ForEach @(
    @{ Problem = 'state' }, @{ Problem = 'runtime binding' }, @{ Problem = 'array runtime binding' }, @{ Problem = 'content' },
    @{ Problem = 'description' }, @{ Problem = 'logProgress' }, @{ Problem = 'logVerbose' }, @{ Problem = 'logActivityTrace' },
    @{ Problem = 'tag value' }, @{ Problem = 'tag removal' }, @{ Problem = 'location' }, @{ Problem = 'runbook identity' }
  ) {
    $fixture = $global:runtimePatchFixture
    $fixture.AfterPatch = switch ($Problem) {
      'state' { { param($f) $f.Runbook.properties.state = 'Edit' } }
      'runtime binding' { { param($f) $f.Runbook.properties.runtimeEnvironment = 'PowerShell-72-Existing' } }
      'array runtime binding' { { param($f) $f.Runbook.properties.runtimeEnvironment = @($f.RuntimeName) } }
      'content' { { param($f) $f.PublishedContent = '# altered by service' } }
      'description' { { param($f) $f.Runbook.properties.description = 'changed' } }
      'logProgress' { { param($f) $f.Runbook.properties.logProgress = $true } }
      'logVerbose' { { param($f) $f.Runbook.properties.logVerbose = $false } }
      'logActivityTrace' { { param($f) $f.Runbook.properties.logActivityTrace = 1 } }
      'tag value' { { param($f) $f.Runbook.tags.Owner = 'changed' } }
      'tag removal' { { param($f) $f.Runbook.PSObject.Properties.Remove('tags') } }
      'location' { { param($f) $f.Runbook.location = 'eastus' } }
      'runbook identity' { { param($f) $f.Runbook.name = 'other-runbook' } }
    }
    { Invoke-RuntimePatchFixture } | Should -Throw
    $fixture.PatchAttempts | Should -Be 1
    Assert-RuntimePatchOnly
    ($fixture.Calls -join '|') | Should -Not -Match 'PUT |POST |DELETE |draft|publish\?'
  }

  It 'stops on a PATCH failure <Failure> and safely retries using live binding' -ForEach @(
    @{ Failure = 'before apply'; ExpectedAttempts = 2; ExpectedChanged = $true },
    @{ Failure = 'after apply'; ExpectedAttempts = 1; ExpectedChanged = $false }
  ) {
    $fixture = $global:runtimePatchFixture
    $fixture.FailPatch = $Failure
    { Invoke-RuntimePatchFixture } | Should -Throw '*simulated runtime PATCH*'
    $fixture.PatchAttempts | Should -Be 1
    $fixture.FailPatch = ''
    Invoke-RuntimePatchFixture | Should -Be $ExpectedChanged
    $fixture.PatchAttempts | Should -Be $ExpectedAttempts
    $fixture.Runbook.properties.runtimeEnvironment | Should -BeExactly $fixture.RuntimeName
    $fixture.Runbook.properties.state | Should -BeExactly 'Published'
    $fixture.PublishedContent | Should -BeExactly $fixture.ExpectedContent
  }
}
