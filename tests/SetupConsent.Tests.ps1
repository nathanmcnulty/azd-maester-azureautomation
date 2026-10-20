BeforeAll {
  $repoRoot = Split-Path $PSScriptRoot -Parent
  # Use the production planner, with all remote authorities replaced by fixtures.
  Import-Module (Join-Path $repoRoot 'scripts/vendor/Azd.MaesterHooks/Maester-ConsentPlan.psm1') -Force
  Import-Module $(if ($env:MAESTER_SETUP_MODULE_UNDER_TEST) { $env:MAESTER_SETUP_MODULE_UNDER_TEST } else { Join-Path $repoRoot 'scripts/Maester-SetupConsent.psm1' }) -Force
  Import-Module $(if ($env:MAESTER_OWNERSHIP_MODULE_UNDER_TEST) { $env:MAESTER_OWNERSHIP_MODULE_UNDER_TEST } else { Join-Path $repoRoot 'scripts/vendor/Azd.MaesterHooks/Maester-OwnershipJournal.psm1' })
}

Describe 'Reviewed deployment setup access (offline)' {
  BeforeAll {
    InModuleScope Maester-SetupConsent {
      function script:Invoke-GraphRestRequest { }
      function script:Get-ServicePrincipal { }
      function script:Get-ManagementRoleAssignment { }
      function script:New-ServicePrincipal { }
      function script:New-ManagementRoleAssignment { }
    }
  }
  BeforeEach {
    $script:savedAccount = $env:MAESTER_SETUP_ACCOUNT
    $script:savedClient = $env:MAESTER_SETUP_CLIENT_ID
    $env:MAESTER_SETUP_ACCOUNT = 'operator@example.test'
    $env:MAESTER_SETUP_CLIENT_ID = '99999999-9999-4999-8999-999999999999'
    InModuleScope Maester-SetupConsent {
      $script:testState = @{
        tenant = '11111111-1111-4111-8111-111111111111'
        principal = '22222222-2222-4222-8222-222222222222'
        user = '33333333-3333-4333-8333-333333333333'
        app = '44444444-4444-4444-8444-444444444444'
        operations = [Collections.Generic.List[object]]::new()
        storageAssignments = @(); teamsAssignments = @(); graphCalls = 0
        groups = @(); malformed = $false; paginated = $false
        easyApps = @(); easyPrincipals = @(); easyGrants = @(); auth = [pscustomobject]@{ properties = @{} }
        exchangePrincipals = @(); exchangeRoles = @(); teamsWriteMode = ''; wrongSpResponse = $false; failAppReadback = $false; grantReadbackMode = ''; wrongAppReadbackId = $false; wrongAzureScope = $false
      }
      $script:parameters = @{
        TenantId = $script:testState.tenant; SubscriptionId = $script:testState.tenant
        PrincipalObjectId = $script:testState.principal
        ResourceId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/automation-test'
        StorageAccount = [pscustomobject]@{ id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/storage'; name = 'storage' }
        ArmHeaders = @{ Authorization = 'offline-only' }; PermissionProfile = 'Full'
        IncludeMailSend = $false; IncludeReportSettingsWrite = $false
      }
      # Scope fake script resolution to the planner and its apply path.
      Mock Join-Path {
        $global:setupGrantFixture
      } -ParameterFilter { $ChildPath -eq 'vendor/Azd.MaesterHooks/Grant-MaesterGraphPermissions.ps1' }
      Mock Invoke-GraphRestRequest {
        param($Method, $Uri, $Body)
        if ($Method -ne 'GET') {
          if ($Uri -like '*/roleManagement/directory/roleAssignments') {
            if ($script:testState.teamsWriteMode -eq 'failure') { throw 'synthetic Teams write failed' }
            if ($script:testState.teamsWriteMode -eq 'unknown') { return [pscustomobject]@{} }
            if ($script:testState.teamsWriteMode -eq 'mismatch') { return [pscustomobject]@{ id='created-assignment'; principalId='ffffffff-ffff-4fff-8fff-ffffffffffff'; roleDefinitionId='88888888-8888-4888-8888-888888888888'; directoryScopeId='/' } }
            if ($script:testState.teamsWriteMode -eq 'checkpoint') {
              $records = @((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records)
              @($records | Where-Object { $_.kind -eq 'AzureRoleAssignment' -and $_.state -eq 'applied' }).Count | Should -Be 1
              @($records | Where-Object { $_.kind -eq 'DirectoryRoleAssignment' -and $_.state -eq 'pending' }).Count | Should -Be 1
              $script:testState.teamsWriteMode = 'verified'
            }
          }
          $script:testState.operations.Add([pscustomobject]@{ method = $Method; uri = $Uri; body = $Body })
          $payload=$Body | ConvertFrom-Json -AsHashtable
          if ($Uri -eq 'https://graph.microsoft.com/v1.0/applications') { return [pscustomobject](@{ id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; appId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' } + $payload) }
          if ($Uri -eq 'https://graph.microsoft.com/v1.0/servicePrincipals') {
            if ($script:testState.wrongSpResponse) { $payload.appId='dddddddd-dddd-4ddd-8ddd-dddddddddddd' }
            return [pscustomobject](@{ id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'; appOwnerOrganizationId=$script:testState.tenant } + $payload)
          }
          if ($Method -eq 'PATCH' -and $Uri -like '*/applications/*') {
            $script:testState.appReadback=$script:testState.easyApps[0] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
            foreach($key in $payload.Keys){$script:testState.appReadback[$key]=$payload[$key]}
            return $null
          }
          if ($Method -eq 'PATCH' -and $Uri -like '*/oauth2PermissionGrants/*') {
            $script:testState.grantReadback=$script:testState.easyGrants[0] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
            foreach($key in $payload.Keys){$script:testState.grantReadback[$key]=$payload[$key]}
            return $null
          }
          return [pscustomobject](@{ id = 'created-assignment' } + $payload)
        }
        if ($Uri -match '/applications/[0-9a-f-]{36}$' -and $script:testState.ContainsKey('appReadback')) {
          if ($script:testState.failAppReadback) { throw 'synthetic exact readback denied' }
          if ($script:testState.wrongAppReadbackId) {
            $receipt=@((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records | Where-Object kind -eq ApplicationConfiguration)[0]
            $receipt.state | Should -BeExactly applied
            $receipt.exactIds.applicationObjectId | Should -BeExactly 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
            $script:testState.appReadback.appId='dddddddd-dddd-4ddd-8ddd-dddddddddddd'
          }
          return $script:testState.appReadback
        }
        if ($Uri -match '/oauth2PermissionGrants/[^?]+$' -and $script:testState.ContainsKey('grantReadback')) {
          if ($script:testState.grantReadbackMode) {
            $receipt=@((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records | Where-Object kind -eq OAuth2PermissionGrant)[0]
            $receipt.state | Should -BeExactly applied
            $receipt.exactIds.grantId | Should -BeExactly 'existing-grant'
            if ($script:testState.grantReadbackMode -eq 'wrong-id') { $script:testState.grantReadback.id='different-grant' }
            if ($script:testState.grantReadbackMode -eq 'principal') { $script:testState.grantReadback.principalId=$script:testState.user }
          }
          return $script:testState.grantReadback
        }
        if ($Uri -like '*/me?*') { return [pscustomobject]@{ id = $script:testState.user; userPrincipalName = $env:MAESTER_SETUP_ACCOUNT } }
        if ($Uri -like "*/servicePrincipals/$($script:testState.principal)[?]*") {
          return [pscustomobject]@{ id = $script:testState.principal; appId = $script:testState.app; displayName = 'test-managed-identity'; servicePrincipalType = 'ManagedIdentity' }
        }
        if ($Uri -like '*/roleManagement/directory/roleDefinitions?*') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = '88888888-8888-4888-8888-888888888888'; displayName = 'Teams Reader'; isBuiltIn = $true }) } }
        if ($Uri -like '*/roleManagement/directory/roleAssignments?*') { return [pscustomobject]@{ value = @($script:testState.teamsAssignments) } }
        if ($Uri -like '*/applications?*') { return [pscustomobject]@{ value = @($script:testState.easyApps) } }
        if ($Uri -like '*/oauth2PermissionGrants?*') { return [pscustomobject]@{ value = @($script:testState.easyGrants) } }
        if ($Uri -like '*00000003-0000-0000-c000-000000000000*') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = '77777777-7777-4777-8777-777777777777'; appId = '00000003-0000-0000-c000-000000000000' }) } }
        if ($Uri -like '*00000002-0000-0ff1-ce00-000000000000*') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = '66666666-6666-4666-8666-666666666666'; appId = '00000002-0000-0ff1-ce00-000000000000'; appRoles = @([pscustomobject]@{ id = 'dc50a0fb-09a3-484d-be87-e023b12c6440'; value = 'Exchange.ManageAsApp'; isEnabled = $true; allowedMemberTypes = @('Application') }) }) } }
        if ($Uri -like '*/servicePrincipals?*') { return [pscustomobject]@{ value = @($script:testState.easyPrincipals) } }
        if ($Uri -like '*/appRoleAssignments?*') { return [pscustomobject]@{ value = @() } }
        if ($Uri -like '*/groups/55555555-5555-4555-8555-555555555555?*') { return [pscustomobject]@{ id = '55555555-5555-4555-8555-555555555555'; securityEnabled = $true } }
        if ($Uri -like '*/groups?*') { return [pscustomobject]@{ value = @($script:testState.groups) } }
        throw "Unexpected offline Graph request: $Method $Uri"
      }
      Mock Invoke-RestMethod {
        param($Method, $Uri, $Body)
        if ($Method -ne 'GET') {
          $script:testState.operations.Add([pscustomobject]@{ method = $Method; uri = $Uri; body = $Body })
          $payload=$Body | ConvertFrom-Json -AsHashtable
          if ($Uri -like '*/authsettingsV2?*') { $script:testState.auth=[pscustomobject]$payload; return $script:testState.auth }
          if ($script:testState.wrongAzureScope) { $payload.properties.scope='/subscriptions/66666666-6666-4666-8666-666666666666' }
          return [pscustomobject]@{ id = ([string]$Uri).Replace('https://management.azure.com','').Split('?')[0]; properties=$payload.properties }
        }
        if ($Uri -like '*/authsettingsV2?*') { return $script:testState.auth }
        if ($script:testState.malformed) { return [pscustomobject]@{ wrong = @() } }
        $result = [pscustomobject]@{ value = @($script:testState.storageAssignments) }
        if ($script:testState.paginated) { $result | Add-Member nextLink 'https://management.azure.com/next' }
        return $result
      }
      Mock Get-ServicePrincipal { @($script:testState.exchangePrincipals) }
      Mock Get-ManagementRoleAssignment { @($script:testState.exchangeRoles) }
      Mock New-ServicePrincipal { $script:testState.operations.Add([pscustomobject]@{ method = 'New-ServicePrincipal' }); [pscustomobject]@{ ObjectId = $script:testState.principal; AppId = $script:testState.app } }
      Mock New-ManagementRoleAssignment { $script:testState.operations.Add([pscustomobject]@{ method = 'New-ManagementRoleAssignment' }); $result=[pscustomobject]@{ Identity = 'owned-exchange-reader'; Role='View-Only Configuration' }; $script:testState.exchangeRoles=@($result); $result }
      Mock Write-Host { }
    }
    $global:setupGrantFixture = Join-Path $TestDrive 'Grant.ps1'
    Set-Content -LiteralPath $global:setupGrantFixture -Value @'
param($TenantId, $PrincipalObjectId, $PermissionProfile, $IncludeMailSend, $IncludeReportSettingsWrite, [switch]$Apply, $ApprovedPlanHash, $OwnershipSession)
$plan = New-MaesterConsentPlan -TenantId $TenantId -PrincipalObjectId $PrincipalObjectId -Capability GraphApplicationRoles -ManifestVersion 'test-1' -ManifestSha256 ('a' * 64) -Desired @('graph-role') -Missing @('graph-role') -Details @{ profile = $PermissionProfile; mail = $IncludeMailSend; reportSettingsWrite = $IncludeReportSettingsWrite }
if ($Apply) { Assert-MaesterConsentPlanApproval -Plan $plan -ApprovedPlanHash $ApprovedPlanHash; $global:setupGraphApplied++ }
else { $plan }
'@
    $global:setupGraphApplied = 0
    $journalRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    $null = New-Item -ItemType Directory -Path $journalRoot
    $global:setupOwnershipSession = Open-MaesterOwnershipJournal -ProjectRoot $journalRoot -Binding @{
      environmentName = 'test'; solutionName = 'automation-account'; tenantId = '11111111-1111-4111-8111-111111111111'
      subscriptionId = '11111111-1111-4111-8111-111111111111'; resourceGroupId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test'
      setupClientId = '99999999-9999-4999-8999-999999999999'; runtimePrincipalId = '22222222-2222-4222-8222-222222222222'
      runtimeResourceId = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/automation-test'
    }
  }
  AfterEach {
    $env:MAESTER_SETUP_ACCOUNT = $script:savedAccount
    $env:MAESTER_SETUP_CLIENT_ID = $script:savedClient
    if ($global:setupOwnershipSession) { $global:setupOwnershipSession.Dispose() }
    Remove-Variable setupOwnershipSession -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable setupGrantFixture, setupGraphApplied -Scope Global -ErrorAction SilentlyContinue
  }
  AfterAll { Remove-Module Maester-SetupConsent, Maester-ConsentPlan -Force -ErrorAction SilentlyContinue }

  It 'plans concrete categorized grants with no writes and a stable hash' {
    InModuleScope Maester-SetupConsent {
      $first = Get-MaesterSetupAccessPlan @parameters
      $second = Get-MaesterSetupAccessPlan @parameters
      $first.planHash | Should -BeExactly $second.planHash
      $first.details.operations[0].category | Should -BeExactly 'StorageReader'
      $first.details.operations[0].body.properties.principalId | Should -BeExactly $testState.user
      $first.details.graphPlanHash | Should -BeExactly $first.details.graphPlan.planHash
      $first.manifestSha256 | Should -BeExactly ('a' * 64)
      $testState.operations.Count | Should -Be 0
    }
    $global:setupGraphApplied | Should -Be 0
  }
  It 'rejects missing and stale approval before every write' {
    InModuleScope Maester-SetupConsent {
      $plan = Get-MaesterSetupAccessPlan @parameters
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash ('0' * 64) } | Should -Throw '*changed after review*'
      $parameters.IncludeMailSend = $true
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession } | Should -Throw '*changed after review*'
      $testState.operations.Count | Should -Be 0
    }
    $global:setupGraphApplied | Should -Be 0
  }
  It 'requires new approval for each changed option or target' -ForEach @('IncludeReportSettingsWrite', 'IncludeTeams', 'PermissionProfile', 'ResourceId') {
    InModuleScope Maester-SetupConsent -Parameters @{ changed = $_ } {
      $plan = Get-MaesterSetupAccessPlan @parameters
      if ($changed -eq 'PermissionProfile') { $parameters[$changed] = 'Extended' }
      elseif ($changed -eq 'ResourceId') { $parameters[$changed] += '-other' }
      else { $parameters[$changed] = $true }
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession } | Should -Throw '*changed after review*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'rejects failed incomplete and paginated authority inventory without writes' -ForEach @('malformed', 'paginated') {
    InModuleScope Maester-SetupConsent -Parameters @{ shape = $_ } {
      $testState[$shape] = $true
      { Get-MaesterSetupAccessPlan @parameters } | Should -Throw '*access inventory*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'applies only the revalidated reviewed operations and separate Graph hash' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeTeams = $true
      $plan = Get-MaesterSetupAccessPlan @parameters
      $result = Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession
      $testState.operations.Count | Should -Be 2
      $result.Receipts.TEAMS_READER_ROLE_ASSIGNMENT_IDS | Should -Contain 'created-assignment'
      ($testState.operations | Where-Object uri -like '*roleManagement*').body | Should -Match '88888888-8888-4888-8888-888888888888'
    }
    $global:setupGraphApplied | Should -Be 1
  }
  It 'preserves already present storage grants without recreating them' {
    InModuleScope Maester-SetupConsent {
      $testState.storageAssignments = @([pscustomobject]@{ id = 'existing'; properties = @{ principalId = $testState.user; roleDefinitionId = "/subscriptions/$($testState.tenant)/providers/Microsoft.Authorization/roleDefinitions/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1" } })
      $plan = Get-MaesterSetupAccessPlan @parameters
      $plan.details.operations.Count | Should -Be 0
      $null = Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'shows new Easy Auth scopes and creates application dependencies in reviewed order' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp = [pscustomobject]@{ id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Web/sites/webapp'; name = 'webapp'; properties = @{ defaultHostName = 'webapp.azurewebsites.net' } }
      $parameters.SecurityGroupObjectId = '55555555-5555-4555-8555-555555555555'
      $plan = Get-MaesterSetupAccessPlan @parameters
      $plan.details.easyAuth.missingDelegatedScopes.Count | Should -Be 4
      @($plan.details.operations | Where-Object category -like 'EasyAuth*' | ForEach-Object receipt) | Should -Be @('EasyAuthApplication', 'EasyAuthPrincipal', '', '')
      $result = Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession
      $result.EasyAuth.clientId | Should -BeExactly 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
      $result.EasyAuth.principalId | Should -BeExactly 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
      $result.Plan.details.easyAuth.clientId | Should -BeExactly '{easyAuthClientId}'
      $result.Plan.details.easyAuth.principalId | Should -BeExactly '{easyAuthPrincipalId}'
      { Assert-MaesterConsentPlanApproval -Plan $result.Plan -ApprovedPlanHash $plan.planHash } | Should -Not -Throw
      @($testState.operations | ForEach-Object body) -join ' ' | Should -Not -Match '\{easyAuth'
      @($testState.operations | Where-Object uri -like '*oauth2PermissionGrants').Count | Should -Be 1
    }
  }
  It 'retains existing Easy Auth delegated permissions and adds only reviewed missing scopes' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp = [pscustomobject]@{ id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Web/sites/webapp'; name = 'webapp'; properties = @{ defaultHostName = 'webapp.azurewebsites.net' } }
      $parameters.SecurityGroupObjectId = '55555555-5555-4555-8555-555555555555'
      $testState.easyApps = @([pscustomobject]@{ id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; appId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; displayName = 'maester-easyauth-webapp'; signInAudience = 'AzureADMyOrg'; groupMembershipClaims = 'SecurityGroup'; web = @{ redirectUris = @('https://webapp.azurewebsites.net/.auth/login/aad/callback'); implicitGrantSettings = @{ enableIdTokenIssuance = $true; enableAccessTokenIssuance = $false } } })
      $testState.easyPrincipals = @([pscustomobject]@{ id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'; appId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; appOwnerOrganizationId = $testState.tenant })
      $testState.easyGrants = @([pscustomobject]@{ id = 'existing-grant'; clientId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'; resourceId = '77777777-7777-4777-8777-777777777777'; consentType = 'AllPrincipals'; scope = 'openid User.Read User.ReadBasic.All' })
      $plan = Get-MaesterSetupAccessPlan @parameters
      $plan.details.easyAuth.missingDelegatedScopes | Should -Be @('profile', 'email')
      $consent = @($plan.details.operations | Where-Object category -eq 'EasyAuthConsent')
      $consent.Count | Should -Be 1
      $consent[0].method | Should -BeExactly 'PATCH'
      $consent[0].body.scope | Should -Match 'User.ReadBasic.All'
      @($plan.details.operations | Where-Object receipt -in @('EasyAuthApplication','EasyAuthPrincipal')).Count | Should -Be 0
    }
  }
  It 'reuses matching Easy Auth configuration and fully consented scopes without access writes' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp = [pscustomobject]@{ id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Web/sites/webapp'; name = 'webapp'; properties = @{ defaultHostName = 'webapp.azurewebsites.net' } }
      $parameters.SecurityGroupObjectId = '55555555-5555-4555-8555-555555555555'
      $testState.easyApps = @([pscustomobject]@{ id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; appId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; displayName = 'maester-easyauth-webapp'; signInAudience = 'AzureADMyOrg'; groupMembershipClaims = 'SecurityGroup'; web = @{ redirectUris = @('https://webapp.azurewebsites.net/.auth/login/aad/callback'); implicitGrantSettings = @{ enableIdTokenIssuance = $true; enableAccessTokenIssuance = $false } } })
      $testState.easyPrincipals = @([pscustomobject]@{ id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'; appId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; appOwnerOrganizationId = $testState.tenant })
      $testState.easyGrants = @([pscustomobject]@{ id = 'existing-grant'; clientId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'; resourceId = '77777777-7777-4777-8777-777777777777'; consentType = 'AllPrincipals'; scope = 'openid profile email User.Read User.ReadBasic.All' })
      $first = Get-MaesterSetupAccessPlan @parameters
      $authOperation = @($first.details.operations | Where-Object category -eq 'EasyAuthConfiguration')[0]
      $testState.auth = $authOperation.body | ConvertTo-Json -Depth 30 | ConvertFrom-Json
      $plan = Get-MaesterSetupAccessPlan @parameters
      @($plan.details.operations | Where-Object category -like 'EasyAuth*').Count | Should -Be 0
      $plan.details.easyAuth.missingDelegatedScopes.Count | Should -Be 0
    }
  }
  It 'rejects ambiguous Easy Auth applications before every permission write' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp = [pscustomobject]@{ id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Web/sites/webapp'; name = 'webapp'; properties = @{ defaultHostName = 'webapp.azurewebsites.net' } }
      $parameters.SecurityGroupObjectId = '55555555-5555-4555-8555-555555555555'
      $testState.easyApps = @([pscustomobject]@{ id = 'one' }, [pscustomobject]@{ id = 'two' })
      { Get-MaesterSetupAccessPlan @parameters } | Should -Throw '*application name is ambiguous*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'requires a new approval when existing Easy Auth configuration changes' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp = [pscustomobject]@{ id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Web/sites/webapp'; name = 'webapp'; properties = @{ defaultHostName = 'webapp.azurewebsites.net' } }
      $parameters.SecurityGroupObjectId = '55555555-5555-4555-8555-555555555555'
      $plan = Get-MaesterSetupAccessPlan @parameters
      $testState.auth = [pscustomobject]@{ properties = @{ platform = @{ enabled = $true } } }
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession } | Should -Throw '*changed after review*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'plans Exchange application access service principal and RBAC separately before writing' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeExchange = $true
      $plan = Get-MaesterSetupAccessPlan @parameters
      $exchange = @($plan.details.operations | Where-Object category -eq 'Exchange')
      $exchange.Count | Should -Be 3
      $exchange[0].body.appRoleId | Should -BeExactly 'dc50a0fb-09a3-484d-be87-e023b12c6440'
      $exchange[1].body.ObjectId | Should -BeExactly $testState.principal
      $exchange[2].body.App | Should -BeExactly $testState.principal
      $testState.operations.Count | Should -Be 0
      $null = Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession
      $testState.operations.Count | Should -Be 4
    }
  }
  It 'rejects a wrong Exchange resource application before permission writes' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeExchange = $true
      Mock Invoke-GraphRestRequest { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'unexpected-resource'; appId = '00000003-0000-0000-c000-000000000000' }) } } -ParameterFilter { $Uri -like '*00000002-0000-0ff1-ce00-000000000000*' }
      { Get-MaesterSetupAccessPlan @parameters } | Should -Throw '*verified Exchange resource*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'rejects a malformed Exchange resource before permission writes' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeExchange = $true
      Mock Invoke-GraphRestRequest { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'unexpected-resource' }) } } -ParameterFilter { $Uri -like '*00000002-0000-0ff1-ce00-000000000000*' }
      { Get-MaesterSetupAccessPlan @parameters } | Should -Throw '*verified Exchange resource*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'fails closed when the selected Exchange inventory cannot be read' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeExchange = $true
      Mock Get-ServicePrincipal { throw 'Exchange inventory denied' }
      { Get-MaesterSetupAccessPlan @parameters } | Should -Throw '*Exchange inventory denied*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'binds Azure Reader to each exact selected subscription' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeAzure = $true
      $parameters.AzureScopes = @('/subscriptions/66666666-6666-4666-8666-666666666666')
      $plan = Get-MaesterSetupAccessPlan @parameters
      $azure = @($plan.details.operations | Where-Object category -eq 'AzureReader')
      $azure[0].body.properties.roleDefinitionId | Should -BeExactly '/subscriptions/66666666-6666-4666-8666-666666666666/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7'
      $parameters.AzureScopes = @('/subscriptions/77777777-7777-4777-8777-777777777777')
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession } | Should -Throw '*changed after review*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'rejects an ambiguous security group before application changes' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp = [pscustomobject]@{ name = 'webapp'; properties = @{ defaultHostName = 'webapp.azurewebsites.net' } }
      $parameters.SecurityGroupDisplayName = 'duplicate-name'
      $testState.groups = @([pscustomobject]@{ id = 'one' }, [pscustomobject]@{ id = 'two' })
      { Get-MaesterSetupAccessPlan @parameters } | Should -Throw '*ambiguous*'
      $testState.operations.Count | Should -Be 0
    }
  }
  It 'retains owned assignment IDs across a successful no-op setup rerun' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeTeams = $true
      $plan = Get-MaesterSetupAccessPlan @parameters
      $first = Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession
      $journal = Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession
      $storage = @($journal.records | Where-Object kind -eq AzureRoleAssignment)[0]
      $testState.storageAssignments = @([pscustomobject]@{ id = $storage.exactIds.roleAssignmentId; properties = @{ principalId = $testState.user; roleDefinitionId = $storage.expected.roleDefinitionId } })
      $testState.teamsAssignments = @([pscustomobject]@{ id = 'created-assignment'; principalId = $testState.principal; roleDefinitionId = '88888888-8888-4888-8888-888888888888'; directoryScopeId = '/' })
      $review = Get-MaesterSetupAccessPlan @parameters
      $review.details.operations.Count | Should -Be 0
      $second = Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $review.planHash -OwnershipSession $global:setupOwnershipSession
      $second.Receipts.TEAMS_READER_ROLE_ASSIGNMENT_IDS | Should -Be $first.Receipts.TEAMS_READER_ROLE_ASSIGNMENT_IDS
      (Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records.Count | Should -Be 2
      $testState.operations.Count | Should -Be 2
    }
  }
  It 'checkpoints the preceding successful response before the next provider write' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeTeams = $true
      $testState.teamsWriteMode = 'checkpoint'
      $plan = Get-MaesterSetupAccessPlan @parameters
      $null = Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession
      @((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records | Where-Object state -eq applied).Count | Should -Be 2
      $testState.teamsWriteMode | Should -BeExactly 'verified'
    }
  }
  It 'retains partial success and a pending failed request and blocks a blind retry' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeTeams = $true
      $testState.teamsWriteMode = 'failure'
      $plan = Get-MaesterSetupAccessPlan @parameters
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession } | Should -Throw '*synthetic Teams write failed*'
      $records = @((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records)
      @($records | Where-Object state -eq applied).Count | Should -Be 1
      @($records | Where-Object state -eq pending).Count | Should -Be 1
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession } | Should -Throw '*Unresolved ownership*'
      $testState.operations.Count | Should -Be 1
    }
  }
  It 'stops on an unknown creation response instead of adopting a name match' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeTeams = $true
      $testState.teamsWriteMode = 'unknown'
      $plan = Get-MaesterSetupAccessPlan @parameters
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession } | Should -Throw
      $records = @((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records)
      @($records | Where-Object { $_.kind -eq 'DirectoryRoleAssignment' -and $_.state -eq 'pending' }).Count | Should -Be 1
      @($records | Where-Object { $_.kind -eq 'DirectoryRoleAssignment' -and $_.exactIds.Count -gt 0 }).Count | Should -Be 0
    }
  }
  It 'stops after a response-checkpoint failure before any later external operation' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeTeams = $true
      Mock Complete-MaesterOwnedOperation { throw 'synthetic durable checkpoint failed' }
      $plan = Get-MaesterSetupAccessPlan @parameters
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession } | Should -Throw '*durable checkpoint failed*'
      $testState.operations.Count | Should -Be 1
      $records = @((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records)
      $records.Count | Should -Be 1
      $records[0].state | Should -BeExactly 'pending'
      $records[0].expected.roleAssignmentId | Should -Match '/providers/Microsoft.Authorization/roleAssignments/'
    }
  }
  It 'refuses unjournaled apply before Graph or ARM writes' {
    InModuleScope Maester-SetupConsent {
      $plan = Get-MaesterSetupAccessPlan @parameters
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash } | Should -Throw '*ownership journal session*'
      $testState.operations.Count | Should -Be 0
    }
    $global:setupGraphApplied | Should -Be 0
  }
  It 'records adopted application and delegated-grant changes without claiming their ownership' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp = [pscustomobject]@{ id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Web/sites/webapp'; name = 'webapp'; properties = @{ defaultHostName = 'webapp.azurewebsites.net' } }
      $parameters.SecurityGroupObjectId = '55555555-5555-4555-8555-555555555555'
      $testState.easyApps = @([pscustomobject]@{ id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; appId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; displayName = 'maester-easyauth-webapp'; signInAudience = 'AzureADMyOrg'; groupMembershipClaims = $null; web = @{ redirectUris = @('https://unrelated.example.test/callback'); implicitGrantSettings = @{ enableIdTokenIssuance = $false; enableAccessTokenIssuance = $false } } })
      $testState.easyPrincipals = @([pscustomobject]@{ id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'; appId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; appOwnerOrganizationId = $testState.tenant })
      $testState.easyGrants = @([pscustomobject]@{ id = 'existing-grant'; clientId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'; resourceId = '77777777-7777-4777-8777-777777777777'; consentType = 'AllPrincipals'; scope = 'openid User.ReadBasic.All' })
      $plan = Get-MaesterSetupAccessPlan @parameters
      $null = Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession
      $records = @((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records)
      @($records | Where-Object kind -in @('EntraApplication','EntraServicePrincipal')).Count | Should -Be 0
      $appChange = @($records | Where-Object kind -eq ApplicationConfiguration)[0]
      $appChange.ownership | Should -BeExactly 'Mutation'
      $appChange.coveredByOperationId | Should -BeNullOrEmpty
      $appChange.before.redirectUris | Should -Contain 'https://unrelated.example.test/callback'
      $grantChange = @($records | Where-Object kind -eq OAuth2PermissionGrant)[0]
      $grantChange.ownership | Should -BeExactly 'Mutation'
      $grantChange.exactIds.grantId | Should -BeExactly 'existing-grant'
      $grantChange.before.scopes | Should -Be @('openid','User.ReadBasic.All')
      $grantChange.after.scopes | Should -Contain 'User.ReadBasic.All'
      $grantChange.coveredByOperationId | Should -BeNullOrEmpty
    }
  }
  It 'retains a pending Exchange principal when the provider returns no identity' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeExchange = $true
      Mock New-ServicePrincipal { $null }
      $plan = Get-MaesterSetupAccessPlan @parameters
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession } | Should -Throw '*nonempty lowercase GUID*'
      $records = @((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records)
      @($records | Where-Object { $_.kind -eq 'ExchangeServicePrincipal' -and $_.state -eq 'pending' }).Count | Should -Be 1
      @($records | Where-Object kind -eq ExchangeRoleAssignment).Count | Should -Be 0
    }
  }

  It 'checkpoints a contradictory creation response then marks conflict before any later provider write' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeTeams=$true; $parameters.IncludeAzure=$true
      $parameters.AzureScopes=@('/subscriptions/66666666-6666-4666-8666-666666666666')
      $testState.teamsWriteMode='mismatch'
      $plan=Get-MaesterSetupAccessPlan @parameters
      { Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession } | Should -Throw '*returned identity tuple*'
      $record=@((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records | Where-Object kind -eq DirectoryRoleAssignment)[0]
      $record.state | Should -BeExactly conflict
      $record.exactIds.assignmentId | Should -BeExactly 'created-assignment'
      $testState.operations.Count | Should -Be 1
    }
  }

  It 'retains exact SP identity when its returned app binding contradicts the approved creation' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp=[pscustomobject]@{id='/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Web/sites/webapp';name='webapp';properties=@{defaultHostName='webapp.azurewebsites.net'}}
      $parameters.SecurityGroupObjectId='55555555-5555-4555-8555-555555555555'
      $testState.wrongSpResponse=$true
      $plan=Get-MaesterSetupAccessPlan @parameters
      {Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession} | Should -Throw '*returned identity tuple*'
      $records=@((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records)
      $sp=@($records | Where-Object kind -eq EntraServicePrincipal)[0]
      $sp.state | Should -BeExactly conflict
      $sp.exactIds.servicePrincipalId | Should -BeExactly 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
      @($records | Where-Object kind -eq OAuth2PermissionGrant).Count | Should -Be 0
    }
  }

  It 'preserves a completed mutation checkpoint as conflict when exact readback fails before later writes' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp=[pscustomobject]@{id='/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Web/sites/webapp';name='webapp';properties=@{defaultHostName='webapp.azurewebsites.net'}}
      $parameters.SecurityGroupObjectId='55555555-5555-4555-8555-555555555555'
      $testState.easyApps=@([pscustomobject]@{id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';appId='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';displayName='maester-easyauth-webapp';signInAudience='AzureADMyOrg';groupMembershipClaims=$null;web=@{redirectUris=@();implicitGrantSettings=@{enableIdTokenIssuance=$false;enableAccessTokenIssuance=$false}}})
      $testState.failAppReadback=$true
      $plan=Get-MaesterSetupAccessPlan @parameters
      {Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession} | Should -Throw '*synthetic exact readback denied*'
      $records=@((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records)
      $mutation=@($records | Where-Object kind -eq ApplicationConfiguration)[0]
      $mutation.state | Should -BeExactly conflict
      $mutation.exactIds.applicationObjectId | Should -BeExactly 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
      @($records | Where-Object kind -eq EntraServicePrincipal).Count | Should -Be 0
      $testState.operations.Count | Should -Be 2
    }
  }

  It 'retains the grant checkpoint and blocks later writes for contradictory PATCH readback: <Mode>' -ForEach @(@{Mode='wrong-id'},@{Mode='principal'}) {
    InModuleScope Maester-SetupConsent -Parameters @{Mode=$Mode} {
      param($Mode)
      $parameters.WebApp=[pscustomobject]@{id='/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Web/sites/webapp';name='webapp';properties=@{defaultHostName='webapp.azurewebsites.net'}}
      $parameters.SecurityGroupObjectId='55555555-5555-4555-8555-555555555555'
      $testState.easyApps=@([pscustomobject]@{id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';appId='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';displayName='maester-easyauth-webapp';signInAudience='AzureADMyOrg';groupMembershipClaims='SecurityGroup';web=@{redirectUris=@('https://webapp.azurewebsites.net/.auth/login/aad/callback');implicitGrantSettings=@{enableIdTokenIssuance=$true;enableAccessTokenIssuance=$false}}})
      $testState.easyPrincipals=@([pscustomobject]@{id='cccccccc-cccc-4ccc-8ccc-cccccccccccc';appId='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';appOwnerOrganizationId=$testState.tenant})
      $testState.easyGrants=@([pscustomobject]@{id='existing-grant';clientId='cccccccc-cccc-4ccc-8ccc-cccccccccccc';resourceId='77777777-7777-4777-8777-777777777777';consentType='AllPrincipals';principalId=$null;scope='openid User.Read'})
      $testState.grantReadbackMode=$Mode
      $plan=Get-MaesterSetupAccessPlan @parameters
      {Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession} | Should -Throw '*Delegated grant readback*'
      $records=@((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records)
      $grant=@($records | Where-Object kind -eq OAuth2PermissionGrant)[0]
      $grant.state | Should -BeExactly conflict
      $grant.exactIds.grantId | Should -BeExactly 'existing-grant'
      $grant.ownership | Should -BeExactly Mutation
      $grant.before.scopes | Should -Be @('openid','User.Read')
      @($records | Where-Object kind -eq WebAppAuthConfiguration).Count | Should -Be 0
      $testState.operations.Count | Should -Be 2
      @($testState.operations | Where-Object uri -Like '*/authsettingsV2?*').Count | Should -Be 0
    }
  }

  It 'retains the application checkpoint when exact readback returns a contradictory appId' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp=[pscustomobject]@{id='/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Web/sites/webapp';name='webapp';properties=@{defaultHostName='webapp.azurewebsites.net'}}
      $parameters.SecurityGroupObjectId='55555555-5555-4555-8555-555555555555'
      $testState.easyApps=@([pscustomobject]@{id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';appId='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';displayName='maester-easyauth-webapp';signInAudience='AzureADMyOrg';groupMembershipClaims=$null;web=@{redirectUris=@();implicitGrantSettings=@{enableIdTokenIssuance=$false;enableAccessTokenIssuance=$false}}})
      $testState.wrongAppReadbackId=$true
      $plan=Get-MaesterSetupAccessPlan @parameters
      {Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession} | Should -Throw '*Application configuration readback*'
      $records=@((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records)
      $mutation=@($records | Where-Object kind -eq ApplicationConfiguration)[0]
      $mutation.state | Should -BeExactly conflict
      $mutation.exactIds.applicationObjectId | Should -BeExactly 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
      $mutation.expected.appId | Should -BeExactly 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
      @($records | Where-Object kind -eq EntraServicePrincipal).Count | Should -Be 0
      $testState.operations.Count | Should -Be 2
    }
  }

  It 'retains the Azure role checkpoint when the response returns a contradictory scope' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeTeams=$true
      $testState.wrongAzureScope=$true
      $plan=Get-MaesterSetupAccessPlan @parameters
      {Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession} | Should -Throw '*Azure role assignment response*'
      $records=@((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records)
      $records.Count | Should -Be 1
      $records[0].kind | Should -BeExactly AzureRoleAssignment
      $records[0].state | Should -BeExactly conflict
      $records[0].exactIds.roleAssignmentId | Should -BeExactly $records[0].expected.roleAssignmentId
      $records[0].expected.scope | Should -BeExactly $parameters.StorageAccount.id
      $testState.operations.Count | Should -Be 1
    }
  }

  It 'composes fresh EasyAuth producer receipts with real cleanup and rejects configuration drift=<Drift>' -ForEach @(@{Drift=$false},@{Drift=$true}) {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp=[pscustomobject]@{id='/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Web/sites/webapp';name='webapp';properties=@{defaultHostName='webapp.azurewebsites.net'}}
      $parameters.SecurityGroupObjectId='55555555-5555-4555-8555-555555555555'
      $plan=Get-MaesterSetupAccessPlan @parameters
      $result=Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession
      $journal=Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession
      $appReceipt=@($journal.records | Where-Object kind -eq EntraApplication)[0]
      $spReceipt=@($journal.records | Where-Object kind -eq EntraServicePrincipal)[0]
      $appReceipt.after.signInAudience | Should -BeExactly AzureADMyOrg
      $appReceipt.after.groupMembershipClaims | Should -BeExactly SecurityGroup
      $appReceipt.after.identifierUris.Count | Should -Be 0
      $appReceipt.after.redirectUris | Should -Be @('https://webapp.azurewebsites.net/.auth/login/aad/callback')
      $spReceipt.expected.creatorPrincipalId | Should -BeExactly $testState.user
      $appBody=(@($testState.operations | Where-Object uri -eq 'https://graph.microsoft.com/v1.0/applications')[0].body | ConvertFrom-Json -AsHashtable)
      $grantBody=(@($testState.operations | Where-Object uri -eq 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants')[0].body | ConvertFrom-Json -AsHashtable)
      $global:setupCleanupFixture=@{
        Root=$global:setupOwnershipSession.Root; Binding=$journal.binding; Creator=$testState.user
        App=(@{id=$result.EasyAuth.objectId;appId=$result.EasyAuth.clientId;passwordCredentials=@();keyCredentials=@()}+$appBody)
        Sp=@{id=$result.EasyAuth.principalId;appId=$result.EasyAuth.clientId;appOwnerOrganizationId=$testState.tenant;passwordCredentials=@();keyCredentials=@()}
        Grant=(@{id='created-assignment'}+$grantBody); AppPresent=$true;SpPresent=$true;GrantPresent=$true;Deletes=[Collections.Generic.List[string]]::new()
      }
    }
    $global:setupOwnershipSession.Dispose(); $global:setupOwnershipSession=$null
    Import-Module (Join-Path $repoRoot 'scripts/vendor/Azd.MaesterHooks/Maester-PreDownCleanup.psm1')
    Mock Get-AzCliSubscriptionContext -ModuleName Maester-PreDownCleanup { }
    Mock Invoke-MaesterCleanupArmRequest -ModuleName Maester-PreDownCleanup {
      param($Binding,$Method,$ResourceId)
      if($ResourceId -like '*/providers/Microsoft.Authorization/roleAssignments'){return @{StatusCode=200;Value=@{value=@()}}}
      return @{StatusCode=404;Value=$null}
    }
    Mock Assert-GraphAccess -ModuleName Maester-PreDownCleanup { }
    Mock Invoke-MaesterCleanupGraphRequest -ModuleName Maester-PreDownCleanup {
      param($Binding,$Method,$Path)
      $s=$global:setupCleanupFixture
      $appPath="/v1.0/applications/$($s.App.id)"; $spPath="/v1.0/servicePrincipals/$($s.Sp.id)"; $grantPath="/v1.0/oauth2PermissionGrants/$($s.Grant.id)"
      if($Method -eq 'DELETE'){
        if($Path -ceq $appPath){$s.AppPresent=$false}elseif($Path -ceq $spPath){$s.SpPresent=$false}elseif($Path -ceq $grantPath){$s.GrantPresent=$false}else{throw "Unexpected cleanup DELETE $Path"}
        $s.Deletes.Add($Path);return @{StatusCode=204;Value=$null}
      }
      foreach($entry in @(@{Path=$appPath;Present=$s.AppPresent;Value=$s.App},@{Path=$spPath;Present=$s.SpPresent;Value=$s.Sp},@{Path=$grantPath;Present=$s.GrantPresent;Value=$s.Grant})){
        if($Path.Split('?')[0] -ceq $entry.Path){return @{StatusCode=if($entry.Present){200}else{404};Value=$entry.Value}}
      }
      if($Path -like '*/owners?*'){return @{StatusCode=200;Value=@{value=@(@{id=$s.Creator})}}}
      if($Path -like '/v1.0/servicePrincipals?*' -and $Path.Contains($s.App.appId)){return @{StatusCode=200;Value=@{value=@(if($s.SpPresent){$s.Sp})}}}
      if($Path -like '/v1.0/oauth2PermissionGrants?*' -and $Path.Contains("clientId eq '$($s.Sp.id)'")){return @{StatusCode=200;Value=@{value=@(if($s.GrantPresent){$s.Grant})}}}
      if($Path -like '/v1.0/*?*' -or $Path -like '*/federatedIdentityCredentials' -or $Path -like '*/appRoleAssignments' -or $Path -like '*/appRoleAssignedTo'){return @{StatusCode=200;Value=@{value=@()}}}
      throw "Unexpected cleanup GET $Path"
    }
    try {
      $s=$global:setupCleanupFixture
      if($Drift){$s.App.web.redirectUris+=@('https://unreviewed.example.test/callback')}
      if($Drift){
        {Get-MaesterOwnedCleanupPlan -ProjectRoot $s.Root -Binding $s.Binding} | Should -Throw '*configuration*'
        $s.Deletes.Count | Should -Be 0
      }else{
        $cleanup=Get-MaesterOwnedCleanupPlan -ProjectRoot $s.Root -Binding $s.Binding
        (Invoke-MaesterOwnedCleanupPostDown -ProjectRoot $s.Root -Binding $s.Binding -ApprovedPlanHash $cleanup.PlanHash).Completed | Should -BeTrue
        $s.Deletes.Count | Should -Be 3
        $s.AppPresent | Should -BeFalse; $s.SpPresent | Should -BeFalse; $s.GrantPresent | Should -BeFalse
      }
    }finally{Remove-Module Maester-PreDownCleanup -Force;Remove-Variable setupCleanupFixture -Scope Global}
  }

  It 'links later configuration and grant mutations only to exact earlier owned parents' {
    InModuleScope Maester-SetupConsent {
      $parameters.WebApp = [pscustomobject]@{ id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test/providers/Microsoft.Web/sites/webapp'; name = 'webapp'; properties = @{ defaultHostName = 'webapp.azurewebsites.net' } }
      $parameters.SecurityGroupObjectId = '55555555-5555-4555-8555-555555555555'
      $first = @{ EasyAuth = @{ objectId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; clientId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; principalId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' } }
      $ownedApp = Start-MaesterOwnedOperation -Session $global:setupOwnershipSession -Key 'prior-app' -Kind EntraApplication -PlanHash ('a' * 64) -Ownership Created -Expected @{ purpose = 'EasyAuth'; displayName = 'maester-easyauth-webapp'; creatorPrincipalId = $testState.user }
      Complete-MaesterOwnedOperation -Session $global:setupOwnershipSession -OperationId $ownedApp.operationId -ExactIds @{ applicationObjectId = $first.EasyAuth.objectId; appId = $first.EasyAuth.clientId }
      $ownedSp = Start-MaesterOwnedOperation -Session $global:setupOwnershipSession -Key 'prior-sp' -Kind EntraServicePrincipal -PlanHash ('a' * 64) -Ownership Created -Expected @{ appId = $first.EasyAuth.clientId }
      Complete-MaesterOwnedOperation -Session $global:setupOwnershipSession -OperationId $ownedSp.operationId -ExactIds @{ servicePrincipalId = $first.EasyAuth.principalId }
      $testState.easyApps = @([pscustomobject]@{ id = $first.EasyAuth.objectId; appId = $first.EasyAuth.clientId; displayName = 'maester-easyauth-webapp'; signInAudience = 'AzureADMyOrg'; groupMembershipClaims = 'All'; web = @{ redirectUris = @('https://webapp.azurewebsites.net/.auth/login/aad/callback'); implicitGrantSettings = @{ enableIdTokenIssuance = $true; enableAccessTokenIssuance = $false } } })
      $testState.easyPrincipals = @([pscustomobject]@{ id = $first.EasyAuth.principalId; appId = $first.EasyAuth.clientId; appOwnerOrganizationId = $testState.tenant })
      $testState.easyGrants = @([pscustomobject]@{ id = 'created-assignment'; clientId = $first.EasyAuth.principalId; resourceId = '77777777-7777-4777-8777-777777777777'; consentType = 'AllPrincipals'; scope = 'openid User.Read' })
      $review = Get-MaesterSetupAccessPlan @parameters
      $null = Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $review.planHash -OwnershipSession $global:setupOwnershipSession
      $records = @((Get-MaesterOwnershipJournal -Session $global:setupOwnershipSession).records)
      $app = @($records | Where-Object kind -eq EntraApplication)[0]
      $sp = @($records | Where-Object kind -eq EntraServicePrincipal)[0]
      $app.expected.creatorPrincipalId | Should -BeExactly $testState.user
      @($records | Where-Object kind -eq ApplicationConfiguration)[0].coveredByOperationId | Should -BeExactly $app.operationId
      @($records | Where-Object { $_.kind -eq 'OAuth2PermissionGrant' -and $_.ownership -eq 'Mutation' })[0].coveredByOperationId | Should -BeExactly $sp.operationId
    }
  }
  It 'records an explicitly approved Azure Reader assignment in another subscription' {
    InModuleScope Maester-SetupConsent {
      $parameters.IncludeAzure = $true
      $parameters.AzureScopes = @('/subscriptions/66666666-6666-4666-8666-666666666666')
      $plan = Get-MaesterSetupAccessPlan @parameters
      $result = Invoke-MaesterSetupAccessPlan -PlanParameters $parameters -ApprovedPlanHash $plan.planHash -OwnershipSession $global:setupOwnershipSession
      $result.Receipts.AZURE_ROLE_ASSIGNMENT_IDS.Count | Should -Be 1
      $result.Receipts.AZURE_ROLE_ASSIGNMENT_IDS[0] | Should -Match '^/subscriptions/66666666-6666-4666-8666-666666666666/providers/Microsoft.Authorization/roleAssignments/'
    }
  }

}

Describe 'Consumer setup entrypoint contract' {
  BeforeAll {
    $setup = Get-Content (Join-Path $repoRoot 'scripts/Setup-PostDeploy.ps1') -Raw
    $wrapper = Get-Content (Join-Path $repoRoot 'scripts/Run-AzdPostProvision.ps1') -Raw
  }
  It 'binds the complete session once and never reconnects or shadows Graph SDK commands' {
    [regex]::Matches($setup, 'Assert-GraphAccess -TenantId').Count | Should -Be 1
    $setup | Should -Match 'Get-MaesterSetupScopes -IncludeTeams:\$IncludeTeams -IncludeWebApp:\$includeWebApp'
    $setup | Should -Not -Match 'Invoke-MgGraphRequest|Connect-MgGraphSilent|Directory.AccessAsUser.All'
    $setup | Should -Match '-ClientId \$env:MAESTER_SETUP_CLIENT_ID -ExpectedAccount \$env:MAESTER_SETUP_ACCOUNT'
    $setup | Should -Match 'AllowContextReplacement:\$AllowGraphContextReplacement'
  }
  It 'supports Full Minimal and legacy Extended without remapping legacy values' {
    $setup | Should -Match "ValidateSet\('Minimal', 'Full', 'Extended'\)"
    $wrapper | Should -Match "ValidateSet\('Minimal', 'Full', 'Extended'\)"
    $setup | Should -Not -Match "if.*PermissionProfile.*Extended.*Full"
  }
  It 'keeps mail and report-setting write capabilities explicitly separate' {
    $setup | Should -Match '\[switch\]\$IncludeMailSend'
    $setup | Should -Match '\[switch\]\$IncludeReportSettingsWrite'
    $setup | Should -Not -Match 'MAIL_RECIPIENT'
    $setup | Should -Match 'if \(-not \$Apply\)'
    $wrapper | Should -Match "capability -eq 'DeploymentSetupAccess'"
  }
}
