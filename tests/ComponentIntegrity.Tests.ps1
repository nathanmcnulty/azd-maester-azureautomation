#Requires -Version 7.6
BeforeAll {
  $root = Split-Path $PSScriptRoot -Parent
  $lock = Get-Content (Join-Path $root 'azd-components.lock.json') -Raw | ConvertFrom-Json
  $permissions = Get-Content (Join-Path $root 'azd-permissions.json') -Raw | ConvertFrom-Json
}

Describe 'Vendored component and permission evidence integrity' {
  It 'pins the reviewed consent flow and retained target guards to an immutable canonical revision' {
    $hooks = @($lock.components | Where-Object id -eq 'maester-azd-hooks')
    $hooks.Count | Should -Be 1
    $hooks[0].version | Should -BeExactly '2.1.0'
    $hooks[0].sourceRepository | Should -BeExactly 'https://github.com/nathanmcnulty/azd-reference'
    $hooks[0].sourceRevision | Should -BeExactly '552ade2f0267e6872bd681f9a1d8a67ac72d055b'
    $hooks[0].files.Count | Should -Be 10
    $coordinator = @($lock.components | Where-Object id -eq 'graph-delegated-authentication')
    $coordinator.Count | Should -Be 1
    $coordinator[0].version | Should -BeExactly '1.1.0'
    $coordinator[0].sourceRevision | Should -BeExactly '552ade2f0267e6872bd681f9a1d8a67ac72d055b'
    $coordinator[0].files.Count | Should -Be 2
  }

  It 'matches every vendored file to its locked SHA-256' {
    foreach ($component in $lock.components) {
      $component.sourceRevision | Should -Match '^[0-9a-f]{40}$'
      foreach ($file in $component.files) {
        $file.sha256 | Should -Match '^[0-9a-f]{64}$'
        (Get-FileHash -LiteralPath (Join-Path $root $file.target) -Algorithm SHA256).Hash.ToLowerInvariant() |
          Should -BeExactly $file.sha256 -Because $file.target
      }
    }
  }

  It 'matches each permission evidence reference to the exact checked-in source' {
    foreach ($requirement in $permissions.requirements) {
      foreach ($evidence in $requirement.evidence) {
        (Get-FileHash -LiteralPath (Join-Path $root $evidence.path) -Algorithm SHA256).Hash.ToLowerInvariant() |
          Should -BeExactly $evidence.sha256 -Because $evidence.path
      }
    }
  }
}
