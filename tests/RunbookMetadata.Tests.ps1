BeforeAll {
  . (Join-Path $PSScriptRoot '../scripts/JobScheduleOwnership.ps1')
  $script:metadataAccountId = '/subscriptions/sub-test/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-test'
  function New-RunbookMetadataFixture {
    @{
      id = "$script:metadataAccountId/runbooks/maester-runbook"; name = 'maester-runbook'
      type = 'Microsoft.Automation/automationAccounts/runbooks'; location = 'West US 2'
      tags = @{ Owner = "Custom 'quoted' Δ"; Empty = '' }
      properties = @{
        state = 'Published'; runbookType = 'PowerShell'; description = "Description with 'quotes' Δ`nand a newline"
        logProgress = $true; logVerbose = $false; logActivityTrace = 4
        publishContentLink = @{ uri = 'https://example.invalid/never-replay' }; draft = @{ inEdit = $true }
        parameters = @{ NeverReplay = @{ type = 'String' } }; outputTypes = @('String')
        creationTime = '2020-01-01'; lastModifiedTime = '2020-02-01'; jobCount = 3; provisioningState = 'Succeeded'
      }
      etag = 'do not replay'; systemData = @{ createdBy = 'do not replay' }
    }
  }
  function Get-FixtureMetadata {
    param([System.Collections.IDictionary]$Runbook)
    Get-MaesterRunbookPreservationMetadata -ExpectedAccountId $script:metadataAccountId -Runbook $Runbook
  }
}

Describe 'Verified existing runbook metadata snapshot' {
  It 'preserves exact mutable values while excluding content, draft and response-only fields' {
    $runbook = New-RunbookMetadataFixture
    $before = $runbook | ConvertTo-Json -Depth 10 -Compress
    $metadata = Get-FixtureMetadata -Runbook $runbook
    ($metadata.Keys -join ',') | Should -BeExactly 'location,properties,tags'
    ($metadata.properties.Keys -join ',') | Should -BeExactly 'description,logProgress,logVerbose,logActivityTrace'
    $metadata.location | Should -BeExactly $runbook.location
    $metadata.properties.description | Should -BeExactly $runbook.properties.description
    $metadata.properties.logProgress | Should -BeTrue
    $metadata.properties.logVerbose | Should -BeFalse
    $metadata.properties.logActivityTrace | Should -Be 4
    $metadata.tags.Owner | Should -BeExactly $runbook.tags.Owner
    $metadata.tags.Empty | Should -BeExactly ''
    ($metadata | ConvertTo-Json -Depth 5 -Compress) | Should -Not -Match 'publishContentLink|never-replay|draft|state|runbookType|parameters|outputTypes|creationTime|lastModifiedTime|jobCount|provisioningState|etag|systemData'
    ($runbook | ConvertTo-Json -Depth 10 -Compress) | Should -BeExactly $before
  }

  It 'retains false, true, zero and an explicitly empty description without defaults' {
    $runbook = New-RunbookMetadataFixture
    $runbook.properties.description = ''; $runbook.properties.logProgress = $false
    $runbook.properties.logVerbose = $true; $runbook.properties.logActivityTrace = 0
    $metadata = Get-FixtureMetadata -Runbook $runbook
    $metadata.properties.description | Should -BeExactly ''
    $metadata.properties.logProgress | Should -BeFalse
    $metadata.properties.logVerbose | Should -BeTrue
    $metadata.properties.logActivityTrace | Should -Be 0
  }

  It 'keeps optional absent fields absent and permits an explicitly empty tags object' {
    $runbook = New-RunbookMetadataFixture
    foreach ($name in @('description', 'logProgress', 'logVerbose', 'logActivityTrace')) { $runbook.properties.Remove($name) }
    $runbook.Remove('tags')
    $metadata = Get-FixtureMetadata -Runbook $runbook
    $metadata.properties.Count | Should -Be 0
    $metadata.Contains('tags') | Should -BeFalse
    $runbook.tags = @{}
    $metadata = Get-FixtureMetadata -Runbook $runbook
    $metadata.Contains('tags') | Should -BeTrue
    $metadata.tags.Count | Should -Be 0
  }

  It 'retains explicit null tags as the untagged state' {
    $runbook = New-RunbookMetadataFixture
    $runbook.tags = $null
    $metadata = Get-FixtureMetadata -Runbook $runbook
    $metadata.Contains('tags') | Should -BeTrue
    $metadata.tags | Should -BeNullOrEmpty
  }

  It 'rejects a present null <Field> rather than inventing a default' -ForEach @(
    @{ Field = 'description' }, @{ Field = 'logProgress' }, @{ Field = 'logVerbose' }, @{ Field = 'logActivityTrace' }
  ) {
    $runbook = New-RunbookMetadataFixture
    if ($Field -eq 'tags') { $runbook.tags = $null } else { $runbook.properties[$Field] = $null }
    { Get-FixtureMetadata -Runbook $runbook } | Should -Throw '*fresh runbook metadata*'
  }

  It 'rejects invalid <Label> value types' -ForEach @(
    @{ Label = 'description'; Field = 'description'; Value = $false },
    @{ Label = 'progress string'; Field = 'logProgress'; Value = 'false' },
    @{ Label = 'verbose number'; Field = 'logVerbose'; Value = 0 },
    @{ Label = 'trace string'; Field = 'logActivityTrace'; Value = '0' },
    @{ Label = 'trace fraction'; Field = 'logActivityTrace'; Value = 0.5 },
    @{ Label = 'trace overflow'; Field = 'logActivityTrace'; Value = [long]2147483648 },
    @{ Label = 'tags array'; Field = 'tags'; Value = @('tag') },
    @{ Label = 'tag number'; Field = 'tags'; Value = @{ Owner = 1 } },
    @{ Label = 'tag null'; Field = 'tags'; Value = @{ Owner = $null } }
  ) {
    $runbook = New-RunbookMetadataFixture
    if ($Field -eq 'tags') { $runbook.tags = $Value } else { $runbook.properties[$Field] = $Value }
    { Get-FixtureMetadata -Runbook $runbook } | Should -Throw '*fresh runbook metadata*'
  }

  It 'rejects a changed <Field> target or missing location' -ForEach @(
    @{ Field = 'id'; Value = '/subscriptions/other/runbooks/maester-runbook' },
    @{ Field = 'name'; Value = 'another-runbook' }, @{ Field = 'type'; Value = 'Microsoft.Web/sites' },
    @{ Field = 'state'; Value = 'Edit' }, @{ Field = 'runbookType'; Value = 'Python3' },
    @{ Field = 'location'; Value = $null }, @{ Field = 'location'; Value = '' }, @{ Field = 'location'; Value = '   ' }
  ) {
    $runbook = New-RunbookMetadataFixture
    if ($Field -in @('state', 'runbookType')) { $runbook.properties[$Field] = $Value } else { $runbook[$Field] = $Value }
    { Get-FixtureMetadata -Runbook $runbook } | Should -Throw '*fresh runbook metadata*'
  }
}
