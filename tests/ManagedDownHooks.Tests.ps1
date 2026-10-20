# Actual host wrappers and canonical ownership/cleanup imports; provider IO only is mocked.
BeforeAll {
  $script:repoRoot = Split-Path $PSScriptRoot -Parent
  $script:solution = 'automation-account'
  $script:provider = 'Microsoft.Automation/automationAccounts'
  $script:savedAz=(Get-Command az -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
  $script:savedAzd=(Get-Command azd -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
  function global:az {
    $s=$global:ManagedDownState; $global:LASTEXITCODE=0
    if ($args[0] -eq 'rest' -and $args -contains "https://management.azure.com/subscriptions/$($s.Subscription)?api-version=2022-12-01") {
      return (@{id="/subscriptions/$($s.Subscription)";subscriptionId=$s.Subscription;tenantId=$s.Tenant;displayName='Offline selected subscription';state='Enabled'} | ConvertTo-Json -Compress)
    }
    throw "Unexpected provider command: az $($args -join ' ')"
  }
  function global:azd {
    $global:LASTEXITCODE=0
    if ($args[0] -eq 'env' -and $args[1] -eq 'get-values') { return ($global:ManagedDownState.Values | ConvertTo-Json -Compress) }
    throw "Unexpected provider command: azd $($args -join ' ')"
  }
  function Invoke-HostDown {
    param([ValidateSet('PreDown','PostDown')]$Phase, [hashtable]$Options = @{})
    & (Join-Path $global:ManagedDownState.Root "scripts/Run-Azd$Phase.ps1") -EnvironmentName 'down-test' -TenantId $global:ManagedDownState.Tenant -SubscriptionId $global:ManagedDownState.Subscription @Options
  }
  function Add-HostOwnedRole {
    param([string]$Id = 'owned-role', [switch]$CascadedGraph)
    $s = $global:ManagedDownState
    $session = Open-MaesterOwnershipJournal -ProjectRoot $s.Root -Binding $s.Binding
    try {
      $expected = if ($CascadedGraph) { @{ principalId = $s.Principal; resourceId = '66666666-6666-4666-8666-666666666666'; appRoleId = '77777777-7777-4777-8777-777777777777' } } else { @{ principalId = $s.Principal; roleDefinitionId = '55555555-5555-4555-8555-555555555555'; directoryScopeId = '/' } }
      $kind = if ($CascadedGraph) { 'GraphAppRoleAssignment' } else { 'DirectoryRoleAssignment' }
      if ($Id -ne 'owned-role' -and -not $CascadedGraph) { $expected.roleDefinitionId = '88888888-8888-4888-8888-888888888888' }
      $record = Start-MaesterOwnedOperation -Session $session -Key $Id -Kind $kind -Ownership Created -PlanHash ('a' * 64) -Expected $expected
      Complete-MaesterOwnedOperation -Session $session -OperationId $record.operationId -ExactIds @{ assignmentId = $Id } | Out-Null
      if (-not $CascadedGraph) { $s.Graph[$Id] = @{ id = $Id } + $expected }
    } finally { $session.Dispose() }
  }
  function Read-HostJournal {
    $s = $global:ManagedDownState
    $session = Open-MaesterOwnershipJournal -ProjectRoot $s.Root -Binding $s.Binding -RequireExisting
    try { return Get-MaesterOwnershipJournal -Session $session } finally { $session.Dispose() }
  }
}

AfterAll {
  Remove-Item function:global:az,function:global:azd -ErrorAction SilentlyContinue
  if ($savedAz) { Set-Item function:global:az $savedAz }
  if ($savedAzd) { Set-Item function:global:azd $savedAzd }
}

Describe 'Actual managed azd down wrappers (offline)' {
  BeforeEach {
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $root
    Copy-Item (Join-Path $repoRoot 'scripts') $root -Recurse
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'infra')
    Set-Content (Join-Path $root 'infra/main.bicep') "targetScope = 'resourceGroup'"
    $vendor = Join-Path $root 'scripts/vendor/Azd.MaesterHooks'
    Import-Module (Join-Path $vendor 'Maester-InfrastructureOwnership.psm1')
    Import-Module (Join-Path $vendor 'Maester-PreDownCleanup.psm1')
    Import-Module (Join-Path $vendor 'Maester-OwnershipJournal.psm1')
    $script:savedEnvironment = @{}
    foreach ($name in @('AZURE_ENV_NAME','AZURE_TENANT_ID','AZURE_SUBSCRIPTION_ID','AZURE_RESOURCE_GROUP','MAESTER_SETUP_CLIENT_ID','MAESTER_SETUP_ACCOUNT','SECURITY_GROUP_OBJECT_ID','EASY_AUTH_SECURITY_GROUP_OBJECT_ID','CI','AZD_NON_INTERACTIVE')) {
      $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
      [Environment]::SetEnvironmentVariable($name,$null)
    }
    $tenant = '11111111-1111-4111-8111-111111111111'; $subscription = '22222222-2222-4222-8222-222222222222'
    $groupId = "/subscriptions/$subscription/resourceGroups/rg-down-test"
    $runtimeId = "$groupId/providers/$provider/runtime"
    $lockId = "$runtimeId/providers/Microsoft.Authorization/locks/owned-lock"
    $principal = '44444444-4444-4444-8444-444444444444'; $client = '33333333-3333-4333-8333-333333333333'
    $global:ManagedDownState = @{
      Root=$root; Tenant=$tenant; Subscription=$subscription; GroupId=$groupId; RuntimeId=$runtimeId; LockId=$lockId; Principal=$principal; Group=$null; ArmPresent=$false; RuntimePresent=$false
      Values=@{ AZURE_ENV_NAME='down-test'; AZURE_TENANT_ID=$tenant; AZURE_SUBSCRIPTION_ID=$subscription; AZURE_RESOURCE_GROUP='rg-down-test'; AZURE_LOCATION='eastus2' }
      Locks=@($lockId); Graph=@{}; GraphDeletes=[Collections.Generic.List[string]]::new(); ArmDeletes=[Collections.Generic.List[string]]::new(); FailDeleteAt=0; DeleteAttempts=0; AuthChecks=0
      Retained=@{setupClient=$client;securityGroup='99999999-9999-4999-8999-999999999999';adoptedApplication='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'}
      Binding=@{ environmentName='down-test'; solutionName=$solution; tenantId=$tenant; subscriptionId=$subscription; resourceGroupId=$groupId; setupClientId=$client; runtimeResourceId=$runtimeId; runtimePrincipalId=$principal }
    }
    $s = $global:ManagedDownState
    $script:infraArgs = @{ ProjectRoot=$root; EnvironmentName='down-test'; SolutionName=$solution; TenantId=$tenant; SubscriptionId=$subscription; ResourceGroupName='rg-down-test' }
    Mock Get-MaesterInfrastructureEnvironment -ModuleName Maester-InfrastructureOwnership { $global:ManagedDownState.Values }
    Mock Set-MaesterInfrastructureResourceGroup -ModuleName Maester-InfrastructureOwnership { }
    Mock Get-AzCliSubscriptionContext -ModuleName Maester-InfrastructureOwnership { }
    Mock Get-AzCliSubscriptionContext -ModuleName Maester-PreDownCleanup { }
    Mock Invoke-MaesterInfrastructureArm -ModuleName Maester-InfrastructureOwnership {
      param($Context,$Method,$Path,$Body)
      $s = $global:ManagedDownState
      if ($Method -eq 'PUT') { $s.Group=@{id=$s.GroupId;tags=$Body.tags;properties=@{provisioningState='Succeeded'}}; $s.ArmPresent=$true; return @{StatusCode=201;Value=$s.Group} }
      if ($Path -match '/resources\?') { return @{StatusCode=200;Value=@{value=@(@{id=$s.RuntimeId})}} }
      if ($Path -match '/providers/Microsoft.Authorization/locks\?') { return @{StatusCode=200;Value=@{value=@($s.Locks | ForEach-Object { @{id=$_;properties=@{level='CanNotDelete'}} })}} }
      if ($Path -match '/providers/Microsoft.Authorization/locks/') {
        $id=$Path.Split('?')[0]
        if ($Method -eq 'DELETE') { $s.ArmDeletes.Add($id); $s.Locks=@($s.Locks | Where-Object {$_ -ne $id}); return @{StatusCode=204;Value=$null} }
        if ($id -in $s.Locks) { return @{StatusCode=200;Value=@{id=$id;properties=@{level='CanNotDelete'}}} }
        return @{StatusCode=404;Value=$null}
      }
      return @{StatusCode=if($s.ArmPresent){200}else{404};Value=$s.Group}
    }
    Mock Invoke-MaesterCleanupArmRequest -ModuleName Maester-PreDownCleanup {
      param($Binding,$Method,$ResourceId)
      if ($Method -ne 'GET') { throw 'Unreviewed ARM authorization mutation' }
      $s=$global:ManagedDownState
      @{StatusCode=if($s.ArmPresent -or ($s.RuntimePresent -and $ResourceId -eq $s.RuntimeId)){200}else{404};Value=@{id=$ResourceId}}
    }
    Mock Assert-GraphAccess -ModuleName Maester-PreDownCleanup { $global:ManagedDownState.AuthChecks++ }
    Mock Invoke-MaesterCleanupGraphRequest -ModuleName Maester-PreDownCleanup {
      param($Binding,$Method,$Path)
      $s=$global:ManagedDownState
      if ($Path -match '^/v1.0/(applications|servicePrincipals)\?') { return @{StatusCode=200;Value=@{value=@(@{id=$s.Retained.setupClient;appId=$s.Retained.setupClient})}} }
      $id=$Path.Split('/')[-1]
      if ($Method -eq 'DELETE') {
        if (-not $s.Graph.ContainsKey($id)) { throw 'Delete target was not an exact fixture-owned role' }
        $s.DeleteAttempts++
        if ($s.FailDeleteAt -eq $s.DeleteAttempts) { throw 'Synthetic provider delete failure' }
        $s.GraphDeletes.Add($id); $s.Graph.Remove($id); return @{StatusCode=204;Value=$null}
      }
      if ($s.Graph.ContainsKey($id)) { return @{StatusCode=200;Value=$s.Graph[$id]} }
      return @{StatusCode=404;Value=$null}
    }
    Mock Test-MaesterCleanupCanPrompt -ModuleName Maester-PreDownCleanup { $true }
    Mock Read-Host -ModuleName Maester-PreDownCleanup { '' }
    Mock Start-Sleep -ModuleName Maester-PreDownCleanup { }
    Mock Write-Host { }
    Initialize-MaesterInfrastructureOwnership @infraArgs | Out-Null
    $s.CreatedReceiptBytes=[IO.File]::ReadAllBytes((Join-Path $root '.azure/down-test/maester-infrastructure-ownership.json'))
    $receipt=Get-Content (Join-Path $root '.azure/down-test/maester-infrastructure-ownership.json') -Raw | ConvertFrom-Json
    $s.Values.MAESTER_INFRASTRUCTURE_OWNERSHIP_ID=$receipt.ownershipId
    $s.Values.MAESTER_OWNED_RESOURCE_IDS=ConvertTo-Json -InputObject @($runtimeId,$lockId) -Compress
    $s.Values.MAESTER_OWNED_LOCK_IDS=ConvertTo-Json -InputObject @($lockId) -Compress
    Complete-MaesterInfrastructureOwnership @infraArgs | Out-Null
  }
  AfterEach {
    foreach($name in $savedEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name])}
    Remove-Module Maester-PreDownCleanup,Maester-InfrastructureOwnership,Maester-OwnershipJournal,Maester-SetupHelpers -Force -ErrorAction SilentlyContinue
    Remove-Variable ManagedDownState -Scope Global -ErrorAction SilentlyContinue
  }

  It 'keeps an interactive plan-only preview read-only through the real wrapper' {
    Register-MaesterExternalSetupStarted @infraArgs | Out-Null; Add-HostOwnedRole
    $result=Invoke-HostDown PreDown @{PlanOnly=$true;InteractiveConsent=$true}
    $result.SafeToDelete | Should -BeFalse
    $global:ManagedDownState.ArmDeletes.Count | Should -Be 0
    $global:ManagedDownState.AuthChecks | Should -Be 0
  }
  It 'rejects omitted, unavailable interactive and stale lock approval without deleting locks or authorization' {
    Register-MaesterExternalSetupStarted @infraArgs | Out-Null; Add-HostOwnedRole
    {Invoke-HostDown PreDown} | Should -Throw '*approval*'
    $savedCi=[Environment]::GetEnvironmentVariable('CI')
    try {
      [Environment]::SetEnvironmentVariable('CI','true')
      {Invoke-HostDown PreDown @{InteractiveConsent=$true}} | Should -Throw '*this process cannot prompt*Down stopped before changing owned locks or Azure resources*'
    } finally { [Environment]::SetEnvironmentVariable('CI',$savedCi) }
    {Invoke-HostDown PreDown @{ApprovedUnlockPlanHash=('0'*64)}} | Should -Throw '*hash*'
    $global:ManagedDownState.ArmDeletes.Count | Should -Be 0
    $global:ManagedDownState.GraphDeletes.Count | Should -Be 0
    $global:ManagedDownState.AuthChecks | Should -Be 0
  }
  It 'unlocks only the approved exact lock while retaining all external roles for ARM deletion' {
    Register-MaesterExternalSetupStarted @infraArgs | Out-Null; Add-HostOwnedRole
    $plan=Invoke-HostDown PreDown @{PlanOnly=$true}
    (Invoke-HostDown PreDown @{ApprovedUnlockPlanHash=$plan.UnlockPlanHash}).SafeToDelete | Should -BeTrue
    @($global:ManagedDownState.ArmDeletes) | Should -Be @($global:ManagedDownState.LockId)
    $global:ManagedDownState.Graph.ContainsKey('owned-role') | Should -BeTrue
    $global:ManagedDownState.AuthChecks | Should -Be 0
  }
  It 'blocks direct postdown while Azure exists before any external authentication or deletion' {
    Register-MaesterExternalSetupStarted @infraArgs | Out-Null; Add-HostOwnedRole
    {Invoke-HostDown PostDown @{ApprovedPlanHash=('a'*64)}} | Should -Throw '*still exists*'
    $global:ManagedDownState.AuthChecks | Should -Be 0
    $global:ManagedDownState.GraphDeletes.Count | Should -Be 0
  }
  It 'requires exact runtime absence even after the bound resource group is absent' {
    Register-MaesterExternalSetupStarted @infraArgs | Out-Null; Add-HostOwnedRole
    $global:ManagedDownState.ArmPresent=$false; $global:ManagedDownState.RuntimePresent=$true
    {Invoke-HostDown PostDown @{PlanOnly=$true}} | Should -Throw '*runtime resource still exists*'
    $global:ManagedDownState.AuthChecks | Should -Be 0
    $global:ManagedDownState.GraphDeletes.Count | Should -Be 0
  }
  It 'rejects default-No and stale postdown approval without authorization writes' {
    Register-MaesterExternalSetupStarted @infraArgs | Out-Null; Add-HostOwnedRole
    $global:ManagedDownState.ArmPresent=$false
    {Invoke-HostDown PostDown @{InteractiveConsent=$true;AllowInteractiveGraphLogin=$true}} | Should -Throw '*not approved*'
    {Invoke-HostDown PostDown @{ApprovedPlanHash=('0'*64)}} | Should -Throw '*hash*'
    $global:ManagedDownState.GraphDeletes.Count | Should -Be 0
  }
  It 'cleans exact external roles and provider-confirmed cascade absence, retaining setup and adopted objects' {
    Register-MaesterExternalSetupStarted @infraArgs | Out-Null; Add-HostOwnedRole; Add-HostOwnedRole -Id 'cascaded-graph-role' -CascadedGraph
    $s=$global:ManagedDownState; $s.ArmPresent=$false; $before=$s.Retained | ConvertTo-Json -Compress
    $s.Values.Remove('MAESTER_OWNED_RESOURCE_IDS'); $s.Values.Remove('MAESTER_OWNED_LOCK_IDS')
    $plan=Invoke-HostDown PostDown @{PlanOnly=$true}
    (Invoke-HostDown PostDown @{ApprovedPlanHash=$plan.PlanHash}).Completed | Should -BeTrue
    $s.GraphDeletes.Count | Should -Be 1
    @((Read-HostJournal).records | Where-Object state -ne deleted).Count | Should -Be 0
    (Invoke-HostDown PostDown).Completed | Should -BeTrue
    $s.GraphDeletes.Count | Should -Be 1
    ($s.Retained | ConvertTo-Json -Compress) | Should -BeExactly $before
  }
  It 'retains a partial postdown checkpoint and resumes only unfinished exact IDs using a fresh approval' {
    Register-MaesterExternalSetupStarted @infraArgs | Out-Null; Add-HostOwnedRole; Add-HostOwnedRole -Id 'second-role'
    $s=$global:ManagedDownState; $s.ArmPresent=$false; $s.FailDeleteAt=2
    $plan=Invoke-HostDown PostDown @{PlanOnly=$true}
    {Invoke-HostDown PostDown @{ApprovedPlanHash=$plan.PlanHash}} | Should -Throw '*external cleanup is incomplete*'
    $records=@((Read-HostJournal).records)
    @($records | Where-Object state -eq deleted).Count | Should -Be 1
    @($records | Where-Object state -eq deleting).Count | Should -Be 1
    $s.FailDeleteAt=0
    $fresh=Invoke-HostDown PostDown @{PlanOnly=$true}
    (Invoke-HostDown PostDown @{ApprovedPlanHash=$fresh.PlanHash}).Completed | Should -BeTrue
    $s.GraphDeletes.Count | Should -Be 2
    $s.DeleteAttempts | Should -Be 3
  }
  It 'completes the fresh infrastructure receipt before optional postprovision setup is declined' {
    $s=$global:ManagedDownState
    $receiptPath=Join-Path $s.Root '.azure/down-test/maester-infrastructure-ownership.json'
    # Restore the exact bytes emitted by this fixture's real initialization,
    # representing successful ARM provisioning before postprovision completed.
    [IO.File]::WriteAllBytes($receiptPath,$s.CreatedReceiptBytes)
    (Get-Content $receiptPath -Raw | ConvertFrom-Json).state | Should -BeExactly Created
    Set-Content (Join-Path $s.Root 'scripts/Setup-PostDeploy.ps1') @'
param($SubscriptionId,$EnvironmentName,$ResourceGroupName,$PermissionProfile,$TenantId)
$receipt=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) ".azure/$EnvironmentName/maester-infrastructure-ownership.json") -Raw | ConvertFrom-Json
if ($receipt.state -cne 'Ready') { throw 'Optional setup ran before infrastructure receipt completion' }
throw 'Optional setup declined before access'
'@
    {& (Join-Path $s.Root 'scripts/Run-AzdPostProvision.ps1') -EnvironmentName down-test -TenantId $s.Tenant -SubscriptionId $s.Subscription -ResourceGroupName rg-down-test} | Should -Throw '*Optional setup declined before access*'
    $receipt=Get-Content $receiptPath -Raw | ConvertFrom-Json
    $receipt.state | Should -BeExactly Ready
    $receipt.externalSetupStarted | Should -BeFalse
    Test-Path (Join-Path $s.Root '.azure/down-test/maester-setup-ownership.json') | Should -BeFalse
    $s.AuthChecks | Should -Be 0
  }
  It 'supports provision-only down only while the durable external-setup marker remains false' {
    $s=$global:ManagedDownState
    $plan=Invoke-HostDown PreDown @{PlanOnly=$true}
    (Invoke-HostDown PreDown @{ApprovedUnlockPlanHash=$plan.PlanHash}).SafeToDelete | Should -BeTrue
    $s.ArmPresent=$false
    (Invoke-HostDown PostDown).ExternalSetupStarted | Should -BeFalse
    $s.AuthChecks | Should -Be 0
    $s.GraphDeletes.Count | Should -Be 0
  }
  It 'blocks both phases when setup began but its external ownership journal was lost' {
    Register-MaesterExternalSetupStarted @infraArgs | Out-Null
    foreach($phase in @('PreDown','PostDown')){{Invoke-HostDown $phase} | Should -Throw '*journal is missing*'}
    $global:ManagedDownState.ArmDeletes.Count | Should -Be 0
    $global:ManagedDownState.AuthChecks | Should -Be 0
  }
  It 'rejects the wrong explicitly selected environment before touching authorization' {
    Register-MaesterExternalSetupStarted @infraArgs | Out-Null; Add-HostOwnedRole
    {& (Join-Path $global:ManagedDownState.Root 'scripts/Run-AzdPostDown.ps1') -EnvironmentName 'wrong' -TenantId $global:ManagedDownState.Tenant -SubscriptionId $global:ManagedDownState.Subscription} | Should -Throw
    $global:ManagedDownState.AuthChecks | Should -Be 0
    $global:ManagedDownState.GraphDeletes.Count | Should -Be 0
  }
}
