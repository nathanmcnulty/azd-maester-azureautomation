Describe 'Blob publication request headers' {
  BeforeAll {
    $runnerPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Invoke-MaesterAutomationRunbook.ps1'
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw 'Runner source did not parse.' }
    $helper = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Set-BlobContent' }, $true)
    if (-not $helper) { throw 'Production Blob upload helper was not found.' }
    . ([scriptblock]::Create($helper.Extent.Text))
    $sourcePath = Join-Path $TestDrive 'source'
    Set-Content -LiteralPath $sourcePath -Value 'offline publication fixture'
  }
  BeforeEach {
    $script:blobRequest = $null
    Mock Invoke-RestMethod {
      $script:blobRequest = [pscustomobject]@{
        Method = $Method; Uri = $Uri; Headers = $Headers.Clone()
        InFile = $InFile; ContentType = $ContentType; Parameters = $PesterBoundParameters.Clone()
      }
    }
  }

  # Put Blob requires Date or x-ms-date on every request, ordinary and bounded uploads alike.
  # https://learn.microsoft.com/en-us/rest/api/storageservices/put-blob#request-headers-all-blob-types
  It 'sends a current invariant UTC date and preserves the <Name> request' -ForEach @(
    @{ Name = 'healthy archive'; Container = 'archive'; BlobName = 'report.html.gz'; ContentType = 'application/gzip'; AccessTier = 'Cool'; ContentEncoding = 'gzip'; BoundedRequest = $false }
    @{ Name = 'healthy latest'; Container = 'latest'; BlobName = 'latest.html'; ContentType = 'text/html'; AccessTier = 'Cool'; ContentEncoding = ''; BoundedRequest = $false }
    @{ Name = 'bounded diagnostic'; Container = 'archive'; BlobName = 'failed/offline-invocation/diagnostics.json'; ContentType = 'application/json'; AccessTier = 'Cool'; ContentEncoding = ''; BoundedRequest = $true }
    @{ Name = 'bounded JUnit'; Container = 'archive'; BlobName = 'failed/offline-invocation/pester-junit.xml'; ContentType = 'application/xml'; AccessTier = 'Cool'; ContentEncoding = ''; BoundedRequest = $true }
  ) {
    $originalCulture = [Globalization.CultureInfo]::CurrentCulture
    try {
      [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
      $before = [datetime]::UtcNow.AddSeconds(-1)
      Set-BlobContent -AccountName 'offlinestorage' -Container $Container -BlobName $BlobName -SourcePath $sourcePath -StorageToken 'offline-token' -ContentType $ContentType -AccessTier $AccessTier -ContentEncoding $ContentEncoding -BoundedRequest:$BoundedRequest
      $after = [datetime]::UtcNow
    }
    finally { [Globalization.CultureInfo]::CurrentCulture = $originalCulture }

    Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    $expectedParameters = @('Method', 'Uri', 'Headers', 'InFile', 'ContentType')
    if ($BoundedRequest) {
      $script:blobRequest.Parameters.ConnectionTimeoutSeconds | Should -Be 10
      $script:blobRequest.Parameters.OperationTimeoutSeconds | Should -Be 30
      $script:blobRequest.Parameters.MaximumRetryCount | Should -Be 0
      $script:blobRequest.Parameters.MaximumRedirection | Should -Be 0
      $expectedParameters += 'ConnectionTimeoutSeconds', 'OperationTimeoutSeconds', 'MaximumRetryCount', 'MaximumRedirection'
    }
    ($script:blobRequest.Parameters.Keys | Sort-Object) -join ',' | Should -BeExactly (($expectedParameters | Sort-Object) -join ',')
    $script:blobRequest.Method | Should -BeExactly 'Put'
    $script:blobRequest.Uri | Should -BeExactly "https://offlinestorage.blob.core.windows.net/$Container/$BlobName"
    $script:blobRequest.InFile | Should -BeExactly $sourcePath
    $script:blobRequest.ContentType | Should -BeExactly $ContentType
    $headers = $script:blobRequest.Headers
    $headers.Authorization | Should -BeExactly 'Bearer offline-token'
    $headers['x-ms-version'] | Should -BeExactly '2021-12-02'
    $headers['x-ms-blob-type'] | Should -BeExactly 'BlockBlob'
    $headers['x-ms-access-tier'] | Should -BeExactly $AccessTier
    $headers['x-ms-date'] | Should -Not -BeNullOrEmpty
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $date = [datetime]::ParseExact($headers['x-ms-date'], 'R', [Globalization.CultureInfo]::InvariantCulture, $styles)
    $date.Kind | Should -Be ([DateTimeKind]::Utc)
    $headers['x-ms-date'] | Should -BeExactly $date.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    $date | Should -BeGreaterOrEqual $before
    $date | Should -BeLessOrEqual $after
    if ($ContentEncoding) {
      $headers['x-ms-blob-content-encoding'] | Should -BeExactly $ContentEncoding
      $headers.Count | Should -Be 6
    }
    else {
      $headers.ContainsKey('x-ms-blob-content-encoding') | Should -BeFalse
      $headers.Count | Should -Be 5
    }
  }
}
