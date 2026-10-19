# Read-only access planning and exact-plan application for deployment operators.
# Hosted runners never import this module or grant their own access.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MaesterSetupCollection {
  param([Parameter(Mandatory)][string]$Uri, [hashtable]$ArmHeaders)
  $response = if ($ArmHeaders) {
    Invoke-RestMethod -Method GET -Uri $Uri -Headers $ArmHeaders
  } else { Invoke-GraphRestRequest -Method GET -Uri $Uri }
  if ($null -eq $response -or -not $response.PSObject.Properties['value'] -or $null -eq $response.value) {
    throw "Incomplete access inventory: $Uri"
  }
  foreach ($property in @('nextLink', '@odata.nextLink')) {
    if ($response.PSObject.Properties[$property] -and $response.$property) {
      throw "Paginated access inventory requires a complete read before setup: $Uri"
    }
  }
  return @($response.value)
}

function Get-MaesterSetupProperty {
  param($Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) { return $Default }
  if ($Object -is [Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
  } elseif ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
  return $Default
}

function Test-MaesterSetupDesiredState {
  param($Actual, $Desired)
  if ($null -eq $Desired) { return $null -eq $Actual }
  if ($Desired -is [Collections.IDictionary]) {
    if ($null -eq $Actual) { return $false }
    foreach ($key in $Desired.Keys) {
      # Read directly so an explicitly empty array remains distinguishable from
      # a missing/null property; pipeline output would enumerate it away.
      if ($Actual -is [Collections.IDictionary]) {
        if (-not $Actual.Contains($key)) { return $false }
        $actualValue = $Actual[$key]
      } else {
        if (-not $Actual.PSObject.Properties[$key]) { return $false }
        $actualValue = $Actual.$key
      }
      if (-not (Test-MaesterSetupDesiredState -Actual $actualValue -Desired $Desired[$key])) { return $false }
    }
    return $true
  }
  if ($Desired -is [Collections.IEnumerable] -and $Desired -isnot [string]) {
    $actualValues = @($Actual); $desiredValues = @($Desired)
    if ($actualValues.Count -ne $desiredValues.Count) { return $false }
    for ($i = 0; $i -lt $desiredValues.Count; $i++) {
      if (-not (Test-MaesterSetupDesiredState $actualValues[$i] $desiredValues[$i])) { return $false }
    }
    return $true
  }
  return $Actual -ceq $Desired
}

function New-MaesterSetupOperation {
  param([string]$Category, [string]$Method, [string]$Uri, $Body, [string]$Receipt)
  [pscustomobject][ordered]@{ category = $Category; method = $Method; uri = $Uri; body = $Body; receipt = $Receipt }
}

function Get-MaesterSetupAccessPlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$PrincipalObjectId,
    [Parameter(Mandatory)][string]$ResourceId,
    [Parameter(Mandatory)]$StorageAccount,
    $WebApp,
    [string]$SecurityGroupObjectId,
    [string]$SecurityGroupDisplayName,
    [Parameter(Mandatory)][hashtable]$ArmHeaders,
    [ValidateSet('Minimal', 'Full', 'Extended')][string]$PermissionProfile = 'Full',
    [bool]$IncludeMailSend = $false,
    [bool]$IncludeReportSettingsWrite = $false,
    [switch]$IncludeExchange,
    [switch]$IncludeTeams,
    [switch]$IncludeAzure,
    [string[]]$AzureScopes
  )
  $grantScript = Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Grant-MaesterGraphPermissions.ps1'
  $graphPlan = & $grantScript -TenantId $TenantId -PrincipalObjectId $PrincipalObjectId `
    -PermissionProfile $PermissionProfile -IncludeMailSend $IncludeMailSend -IncludeReportSettingsWrite $IncludeReportSettingsWrite
  if (-not $graphPlan -or $graphPlan.schemaVersion -cne '1.0' -or $graphPlan.planHash -notmatch '^[a-f0-9]{64}$') {
    throw 'The canonical Graph permission planner did not return a versioned plan.'
  }
  $operations = [Collections.Generic.List[object]]::new()
  $inventory = [ordered]@{}
  $principal = Invoke-GraphRestRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/${PrincipalObjectId}?`$select=id,appId,displayName,servicePrincipalType"
  if ($principal.id -ine $PrincipalObjectId -or $principal.servicePrincipalType -cne 'ManagedIdentity') {
    throw 'The setup target must be the verified deployment managed identity.'
  }
  $inventory['principal'] = [ordered]@{ id = $principal.id; appId = $principal.appId; displayName = $principal.displayName }

  $user = Invoke-GraphRestRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName'
  if (-not $user.id -or $user.userPrincipalName -ine $env:MAESTER_SETUP_ACCOUNT) {
    throw 'Storage reader access requires the explicitly selected setup account.'
  }
  $inventory['operator'] = [ordered]@{ id = $user.id; userPrincipalName = $user.userPrincipalName }
  $storageRoleId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"
  $storageAssignments = @(Get-MaesterSetupCollection -Uri "https://management.azure.com$($StorageAccount.id)/providers/Microsoft.Authorization/roleAssignments?`$filter=atScope()&api-version=2022-04-01" -ArmHeaders $ArmHeaders)
  $storageMatches = @($storageAssignments | Where-Object { $_.properties.principalId -eq $user.id -and $_.properties.roleDefinitionId -eq $storageRoleId })
  $inventory['storageReader'] = @($storageMatches | ForEach-Object id | Sort-Object)
  if ($storageMatches.Count -eq 0) {
    $operations.Add((New-MaesterSetupOperation 'StorageReader' 'PUT' "$($StorageAccount.id)/providers/Microsoft.Authorization/roleAssignments/{assignmentId}?api-version=2022-04-01" `
      ([ordered]@{ properties = [ordered]@{ roleDefinitionId = $storageRoleId; principalId = $user.id; principalType = 'User' } }) ''))
  }

  if ($IncludeExchange) {
    $exchange = @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000002-0000-0ff1-ce00-000000000000'&`$select=id,appId,appRoles")
    if ($exchange.Count -ne 1 -or (Get-MaesterSetupProperty $exchange[0] 'appId') -cne '00000002-0000-0ff1-ce00-000000000000' -or
        [string]::IsNullOrWhiteSpace([string](Get-MaesterSetupProperty $exchange[0] 'id'))) {
      throw 'Exactly one verified Exchange resource service principal is required.'
    }
    $roleId = 'dc50a0fb-09a3-484d-be87-e023b12c6440'
    $roles = @($exchange[0].appRoles | Where-Object { $_.id -eq $roleId -and $_.value -eq 'Exchange.ManageAsApp' -and $_.isEnabled -eq $true -and 'Application' -in $_.allowedMemberTypes })
    if ($roles.Count -ne 1) { throw 'Exchange.ManageAsApp must be an enabled application role.' }
    $assignments = @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalObjectId/appRoleAssignments?`$top=999")
    $matches = @($assignments | Where-Object { $_.principalId -eq $PrincipalObjectId -and $_.resourceId -eq $exchange[0].id -and $_.appRoleId -eq $roleId })
    $inventory['exchangeApplicationRole'] = @($matches | ForEach-Object id | Sort-Object)
    if ($matches.Count -eq 0) {
      $operations.Add((New-MaesterSetupOperation 'Exchange' 'POST' "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalObjectId/appRoleAssignments" `
        ([ordered]@{ principalId = $PrincipalObjectId; resourceId = $exchange[0].id; appRoleId = $roleId }) 'EXO_APPROLE_ASSIGNMENT_IDS'))
    }
    # The Exchange session is established by the entrypoint before planning. A
    # failed or unavailable inventory is never treated as permission to grant.
    $exchangePrincipals = @(Get-ServicePrincipal -ErrorAction Stop | Where-Object { $_.ObjectId -eq $PrincipalObjectId -or $_.AppId -eq $principal.appId })
    if ($exchangePrincipals.Count -gt 1 -or ($exchangePrincipals.Count -eq 1 -and
        ($exchangePrincipals[0].ObjectId -ne $PrincipalObjectId -or $exchangePrincipals[0].AppId -ne $principal.appId))) {
      throw 'Exchange service principal identity is ambiguous or does not match the managed identity.'
    }
    $exchangeRoles = @()
    if ($exchangePrincipals.Count -eq 1) {
      $exchangeRoles = @(Get-ManagementRoleAssignment -RoleAssignee $PrincipalObjectId -ErrorAction Stop | Where-Object { [string]$_.Role -eq 'View-Only Configuration' })
    } else {
      $operations.Add((New-MaesterSetupOperation 'Exchange' 'New-ServicePrincipal' $PrincipalObjectId `
        ([ordered]@{ AppId = $principal.appId; ObjectId = $PrincipalObjectId; DisplayName = $principal.displayName }) ''))
    }
    $inventory['exchangeServicePrincipal'] = @($exchangePrincipals | ForEach-Object { [ordered]@{ ObjectId = [string]$_.ObjectId; AppId = [string]$_.AppId } })
    $inventory['exchangeRbac'] = @($exchangeRoles | ForEach-Object { [string]$_.Identity } | Sort-Object)
    if ($exchangeRoles.Count -eq 0) {
      $operations.Add((New-MaesterSetupOperation 'Exchange' 'New-ManagementRoleAssignment' $PrincipalObjectId `
        ([ordered]@{ Role = 'View-Only Configuration'; App = $PrincipalObjectId }) ''))
    }
  }
  if ($IncludeTeams) {
    $definitions = @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?`$filter=displayName eq 'Teams Reader'&`$select=id,displayName,isBuiltIn")
    if ($definitions.Count -ne 1 -or $definitions[0].displayName -cne 'Teams Reader' -or $definitions[0].isBuiltIn -ne $true) { throw 'Exactly one built-in Teams Reader role definition is required.' }
    $definitionId = $definitions[0].id
    $assignments = @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$PrincipalObjectId' and roleDefinitionId eq '$definitionId' and directoryScopeId eq '/'&`$select=id,principalId,roleDefinitionId,directoryScopeId")
    if (@($assignments | Where-Object { $_.principalId -ne $PrincipalObjectId -or $_.roleDefinitionId -ne $definitionId -or $_.directoryScopeId -ne '/' }).Count) { throw 'Unexpected Teams role assignment inventory.' }
    $inventory['teams'] = @($assignments | ForEach-Object id | Sort-Object)
    if ($assignments.Count -eq 0) {
      $operations.Add((New-MaesterSetupOperation 'Teams' 'POST' 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' `
        ([ordered]@{ principalId = $PrincipalObjectId; roleDefinitionId = $definitionId; directoryScopeId = '/' }) 'TEAMS_READER_ROLE_ASSIGNMENT_IDS'))
    }
  }
  $azureInventory = [ordered]@{}
  if ($IncludeAzure) {
    foreach ($scope in @($AzureScopes | Sort-Object -Unique)) {
      if ($scope -notmatch '^/subscriptions/[0-9a-fA-F-]{36}$' -and $scope -notmatch '^/providers/Microsoft.Management/managementGroups/[A-Za-z0-9_.()-]+$') {
        throw "Azure Reader scope must be an explicit subscription or management group: $scope"
      }
      $roleRoot = if ($scope -like '/subscriptions/*') { $scope } else { '' }
      $roleId = "$roleRoot/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
      $assignments = @(Get-MaesterSetupCollection -Uri "https://management.azure.com$scope/providers/Microsoft.Authorization/roleAssignments?`$filter=atScope()&api-version=2022-04-01" -ArmHeaders $ArmHeaders)
      $matches = @($assignments | Where-Object { $_.properties.principalId -eq $PrincipalObjectId -and $_.properties.roleDefinitionId -eq $roleId })
      $azureInventory[$scope] = @($matches | ForEach-Object id | Sort-Object)
      if ($matches.Count -eq 0) {
        $operations.Add((New-MaesterSetupOperation 'AzureReader' 'PUT' "$scope/providers/Microsoft.Authorization/roleAssignments/{assignmentId}?api-version=2022-04-01" `
          ([ordered]@{ properties = [ordered]@{ roleDefinitionId = $roleId; principalId = $PrincipalObjectId; principalType = 'ServicePrincipal' } }) 'AZURE_ROLE_ASSIGNMENT_IDS'))
      }
    }
  }
  $inventory['azureReader'] = $azureInventory

  $easyAuth = $null
  if ($WebApp) {
    if (-not $SecurityGroupObjectId) {
      if (-not $SecurityGroupDisplayName) { throw 'An explicit Easy Auth security group is required before planning.' }
      $escaped = [uri]::EscapeDataString("'$($SecurityGroupDisplayName.Replace("'", "''"))'")
      $groups = @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq $escaped&`$select=id,securityEnabled")
      if ($groups.Count -ne 1) { throw 'Security group name is missing or ambiguous; provide its exact object ID.' }
      $SecurityGroupObjectId = [string]$groups[0].id
    }
    $groupGuid = [guid]::Empty
    if (-not [guid]::TryParse($SecurityGroupObjectId, [ref]$groupGuid) -or $groupGuid -eq [guid]::Empty) { throw 'SecurityGroupObjectId must be a non-empty GUID.' }
    $group = Invoke-GraphRestRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/${SecurityGroupObjectId}?`$select=id,securityEnabled"
    if ($group.id -ine $SecurityGroupObjectId -or $group.securityEnabled -ne $true) { throw 'Easy Auth requires the exact enabled security group.' }
    $displayName = "maester-easyauth-$($WebApp.name)"
    $escapedName = [uri]::EscapeDataString("'$($displayName.Replace("'", "''"))'")
    $apps = @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq $escapedName")
    if ($apps.Count -gt 1) { throw 'Easy Auth application name is ambiguous; do not consent a first match.' }
    $app = if ($apps.Count -eq 1) { $apps[0] } else { $null }
    if ($app -and ($app.displayName -cne $displayName -or $app.signInAudience -cne 'AzureADMyOrg')) { throw 'Easy Auth application must be the exact single-tenant application.' }
    $appId = if ($app) { [string]$app.appId } else { '{easyAuthClientId}' }
    $redirectUri = "https://$($WebApp.properties.defaultHostName)/.auth/login/aad/callback"
    $redirects = @(@(Get-MaesterSetupProperty (Get-MaesterSetupProperty $app 'web') 'redirectUris' @()) + $redirectUri | Sort-Object -Unique)
    $appBody = [ordered]@{ groupMembershipClaims = 'SecurityGroup'; web = [ordered]@{ redirectUris = $redirects; implicitGrantSettings = [ordered]@{ enableIdTokenIssuance = $true; enableAccessTokenIssuance = $false } } }
    $inventory['easyAuthApplication'] = if ($app) { [ordered]@{ id = $app.id; appId = $app.appId; groupMembershipClaims = (Get-MaesterSetupProperty $app 'groupMembershipClaims'); web = (Get-MaesterSetupProperty $app 'web') } } else { $null }
    if (-not $app) {
      $appBody['displayName'] = $displayName; $appBody['signInAudience'] = 'AzureADMyOrg'; $appBody['identifierUris'] = @()
      $operations.Add((New-MaesterSetupOperation 'EasyAuth' 'POST' 'https://graph.microsoft.com/v1.0/applications' $appBody 'EasyAuthApplication'))
    } else {
      $web = Get-MaesterSetupProperty $app 'web'
      $implicit = Get-MaesterSetupProperty $web 'implicitGrantSettings'
      if ((Get-MaesterSetupProperty $app 'groupMembershipClaims') -cne 'SecurityGroup' -or
          (Get-MaesterSetupProperty $implicit 'enableIdTokenIssuance') -ne $true -or
          (Get-MaesterSetupProperty $implicit 'enableAccessTokenIssuance') -ne $false -or
          $redirectUri -notin @(Get-MaesterSetupProperty $web 'redirectUris' @())) {
        $operations.Add((New-MaesterSetupOperation 'EasyAuth' 'PATCH' "https://graph.microsoft.com/v1.0/applications/$($app.id)" $appBody ''))
      }
    }
    $servicePrincipals = @(if ($app) { @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$appId'") } else { @() })
    if ($servicePrincipals.Count -gt 1) { throw 'Easy Auth service principal is ambiguous.' }
    $sp = if ($servicePrincipals.Count -eq 1) { $servicePrincipals[0] } else { $null }
    if ($sp -and ($sp.appId -ine $appId -or $sp.appOwnerOrganizationId -ine $TenantId)) { throw 'Easy Auth service principal is not owned by the selected tenant.' }
    $spId = if ($sp) { [string]$sp.id } else { '{easyAuthPrincipalId}' }
    $inventory['easyAuthPrincipal'] = if ($sp) { [string]$sp.id } else { $null }
    if (-not $sp) {
      $operations.Add((New-MaesterSetupOperation 'EasyAuth' 'POST' 'https://graph.microsoft.com/v1.0/servicePrincipals' ([ordered]@{ appId = $appId }) 'EasyAuthPrincipal'))
    }
    $graph = @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appId")
    if ($graph.Count -ne 1 -or $graph[0].appId -ne '00000003-0000-0000-c000-000000000000') { throw 'Exactly one Microsoft Graph resource is required for Easy Auth.' }
    $grants = @(if ($sp) { @(Get-MaesterSetupCollection -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$spId' and resourceId eq '$($graph[0].id)' and consentType eq 'AllPrincipals'") } else { @() })
    if ($grants.Count -gt 1) { throw 'Easy Auth tenant-wide delegated grant is ambiguous.' }
    $grant = if ($grants.Count -eq 1) { $grants[0] } else { $null }
    if ($grant -and ($grant.clientId -ne $spId -or $grant.resourceId -ne $graph[0].id -or $grant.consentType -cne 'AllPrincipals')) { throw 'Unexpected Easy Auth delegated grant target.' }
    $currentScopes = if ($grant) { @($grant.scope -split '\s+' | Where-Object { $_ }) } else { @() }
    $desiredScopes = @($currentScopes + @('openid', 'profile', 'email', 'User.Read') | Sort-Object -Unique)
    $missingScopes = @('openid', 'profile', 'email', 'User.Read' | Where-Object { $_ -notin $currentScopes })
    $inventory['easyAuthGrant'] = if ($grant) { [ordered]@{ id = $grant.id; scope = ($currentScopes | Sort-Object) -join ' ' } } else { $null }
    if ($missingScopes.Count -gt 0) {
      if ($grant) {
        $operations.Add((New-MaesterSetupOperation 'EasyAuthConsent' 'PATCH' "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($grant.id)" ([ordered]@{ scope = $desiredScopes -join ' ' }) ''))
      } else {
        $operations.Add((New-MaesterSetupOperation 'EasyAuthConsent' 'POST' 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' ([ordered]@{ clientId = $spId; consentType = 'AllPrincipals'; resourceId = $graph[0].id; scope = $desiredScopes -join ' ' }) ''))
      }
    }
    $authUri = "$($WebApp.id)/config/authsettingsV2?api-version=2023-12-01"
    $currentAuth = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$authUri" -Headers $ArmHeaders
    if ($null -eq $currentAuth -or -not $currentAuth.PSObject.Properties['properties']) { throw 'Easy Auth current settings could not be read.' }
    $inventory['easyAuthSettings'] = $currentAuth.properties
    $inventory['easyAuthWebAppId'] = [string]$WebApp.id
    $inventory['easyAuthGraphResourceId'] = [string]$graph[0].id
    $authBody = [ordered]@{ properties = [ordered]@{
      platform = [ordered]@{ enabled = $true }
      globalValidation = [ordered]@{ requireAuthentication = $true; unauthenticatedClientAction = 'RedirectToLoginPage' }
      httpSettings = [ordered]@{ requireHttps = $true }
      identityProviders = [ordered]@{ azureActiveDirectory = [ordered]@{
        enabled = $true
        registration = [ordered]@{ clientId = $appId; openIdIssuer = "https://login.microsoftonline.com/$TenantId/v2.0" }
        validation = [ordered]@{ allowedAudiences = @("https://$($WebApp.properties.defaultHostName)"); defaultAuthorizationPolicy = [ordered]@{ allowedPrincipals = [ordered]@{ groups = @($SecurityGroupObjectId) } } }
      } }
      login = [ordered]@{ routes = @{} }
    } }
    # A matching configuration is reused without another write or consent.
    if (-not (Test-MaesterSetupDesiredState -Actual $currentAuth -Desired $authBody)) {
      $operations.Add((New-MaesterSetupOperation 'EasyAuthConfiguration' 'PUT' $authUri $authBody ''))
    }
    $easyAuth = [ordered]@{ objectId = $(if ($app) { [string]$app.id } else { '' }); clientId = $appId; principalId = $spId; displayName = $displayName; securityGroupId = $SecurityGroupObjectId; missingDelegatedScopes = $missingScopes }
  }
  $details = @{
    subscriptionId = $SubscriptionId; resourceId = $ResourceId; storageAccountId = $StorageAccount.id
    setupClientId = $env:MAESTER_SETUP_CLIENT_ID; setupAccount = $env:MAESTER_SETUP_ACCOUNT
    graphPlanHash = $graphPlan.planHash; graphPlan = $graphPlan
    includeExchange = [bool]$IncludeExchange; includeTeams = [bool]$IncludeTeams; includeAzure = [bool]$IncludeAzure
    includeMailSend = $IncludeMailSend; includeReportSettingsWrite = $IncludeReportSettingsWrite
    azureScopes = @($AzureScopes | Sort-Object -Unique); easyAuth = $easyAuth; inventory = $inventory; operations = @($operations.ToArray())
  }
  $operationValues = @($operations | ForEach-Object { $_ | ConvertTo-Json -Depth 30 -Compress })
  $missing = @($graphPlan.missing | ForEach-Object { "Graph:$_" }) + $operationValues
  $desired = @($graphPlan.desired | ForEach-Object { "Graph:$_" }) + $operationValues
  New-MaesterConsentPlan -TenantId $TenantId -PrincipalObjectId $PrincipalObjectId -Capability 'DeploymentSetupAccess' `
    -ManifestVersion $graphPlan.manifestVersion -ManifestSha256 $graphPlan.manifestSha256 `
    -Desired $desired -Missing $missing -Details $details
}

function Get-MaesterSetupOwnedParent {
  param($Session, [string]$Kind, [string]$IdName, [string]$Id)
  if (-not $Id -or $Id.StartsWith('{')) { return $null }
  $matches = @((Get-MaesterOwnershipJournal -Session $Session).records | Where-Object {
    $_.kind -ceq $Kind -and $_.ownership -ceq 'Created' -and $_.state -ceq 'applied' -and
    (Get-MaesterSetupProperty $_.exactIds $IdName) -ceq $Id
  })
  if ($matches.Count -gt 1) { throw 'Multiple ownership receipts describe the same setup parent.' }
  if ($matches.Count -eq 1) { return [string]$matches[0].operationId }
  return $null
}

function Get-MaesterEasyAuthApplicationValues {
  param($Application)
  $web = Get-MaesterSetupProperty $Application 'web'
  $implicit = Get-MaesterSetupProperty $web 'implicitGrantSettings'
  [ordered]@{
    groupMembershipClaims = Get-MaesterSetupProperty $Application 'groupMembershipClaims'
    redirectUris = @(Get-MaesterSetupProperty $web 'redirectUris' @())
    enableIdTokenIssuance = Get-MaesterSetupProperty $implicit 'enableIdTokenIssuance' $false
    enableAccessTokenIssuance = Get-MaesterSetupProperty $implicit 'enableAccessTokenIssuance' $false
  }
}

function Get-MaesterWebAuthValues {
  param($Properties)
  $platform = Get-MaesterSetupProperty $Properties 'platform'
  $validation = Get-MaesterSetupProperty $Properties 'globalValidation'
  $http = Get-MaesterSetupProperty $Properties 'httpSettings'
  $aad = Get-MaesterSetupProperty (Get-MaesterSetupProperty $Properties 'identityProviders') 'azureActiveDirectory'
  $registration = Get-MaesterSetupProperty $aad 'registration'
  $aadValidation = Get-MaesterSetupProperty $aad 'validation'
  $groups = Get-MaesterSetupProperty (Get-MaesterSetupProperty (Get-MaesterSetupProperty $aadValidation 'defaultAuthorizationPolicy') 'allowedPrincipals') 'groups' @()
  # Only explicitly supported non-secret fields enter the ownership journal.
  [ordered]@{
    enabled = Get-MaesterSetupProperty $platform 'enabled' $false
    requireAuthentication = Get-MaesterSetupProperty $validation 'requireAuthentication' $false
    unauthenticatedClientAction = Get-MaesterSetupProperty $validation 'unauthenticatedClientAction' ''
    requireHttps = Get-MaesterSetupProperty $http 'requireHttps' $false
    issuer = Get-MaesterSetupProperty $registration 'openIdIssuer' ''
    allowedAudiences = @(Get-MaesterSetupProperty $aadValidation 'allowedAudiences' @())
    allowedGroups = @($groups)
  }
}

function Get-MaesterSetupOperationOwnership {
  param($Session, $Operation, $Body, $Plan, $EasyAuth)
  $result = @{ Ownership = 'Created'; Expected = @{} }
  switch ($Operation.category) {
    { $_ -in @('StorageReader', 'AzureReader') } {
      $result.Kind = 'AzureRoleAssignment'
      $scope = $Operation.uri.Split('/providers/Microsoft.Authorization/roleAssignments/')[0]
      $result.Expected = @{ principalId = $Body.properties.principalId; roleDefinitionId = $Body.properties.roleDefinitionId; scope = $scope; principalType = $Body.properties.principalType }
    }
    'Teams' {
      $result.Kind = 'DirectoryRoleAssignment'; $result.Expected = @{ principalId = $Body.principalId; roleDefinitionId = $Body.roleDefinitionId; directoryScopeId = $Body.directoryScopeId }
    }
    'Exchange' {
      switch ($Operation.method) {
        'POST' { $result.Kind = 'GraphAppRoleAssignment'; $result.Expected = @{ principalId = $Body.principalId; resourceId = $Body.resourceId; appRoleId = $Body.appRoleId } }
        'New-ServicePrincipal' { $result.Kind = 'ExchangeServicePrincipal'; $result.Expected = @{ appId = $Body.AppId; servicePrincipalId = $Body.ObjectId } }
        'New-ManagementRoleAssignment' {
          $result.Kind = 'ExchangeRoleAssignment'; $result.Expected = @{ servicePrincipalId = $Body.App; roleName = $Body.Role }
          $result.CoveredByOperationId = Get-MaesterSetupOwnedParent $Session 'ExchangeServicePrincipal' 'exchangeServicePrincipalId' $Body.App
        }
        default { throw 'Unrecognized reviewed Exchange setup operation.' }
      }
    }
    'EasyAuth' {
      if ($Operation.receipt -ceq 'EasyAuthApplication') {
        $result.Kind = 'EntraApplication'; $result.Expected = @{ purpose = 'EasyAuth'; displayName = $Body.displayName; creatorPrincipalId = $Plan.details.inventory.operator.id; tenantId = $Plan.tenantId; webAppResourceId = $Plan.details.inventory.easyAuthWebAppId }
        $result.After = Get-MaesterEasyAuthApplicationValues $Body
        $result.After['identifierUris'] = @($Body.identifierUris)
        $result.After['signInAudience'] = $Body.signInAudience
      } elseif ($Operation.receipt -ceq 'EasyAuthPrincipal') {
        $result.Kind = 'EntraServicePrincipal'; $result.Expected = @{ appId = $Body.appId; appOwnerOrganizationId = $Plan.tenantId; creatorPrincipalId = $Plan.details.inventory.operator.id }
        $result.CoveredByOperationId = Get-MaesterSetupOwnedParent $Session 'EntraApplication' 'appId' $Body.appId
      } elseif ($Operation.method -ceq 'PATCH') {
        $result.Kind = 'ApplicationConfiguration'; $result.Ownership = 'Mutation'
        $result.Expected = @{ applicationObjectId = $EasyAuth.objectId; appId = $EasyAuth.clientId }
        $result.Before = Get-MaesterEasyAuthApplicationValues $Plan.details.inventory.easyAuthApplication
        $result.After = Get-MaesterEasyAuthApplicationValues $Body
        $result.CoveredByOperationId = Get-MaesterSetupOwnedParent $Session 'EntraApplication' 'applicationObjectId' $EasyAuth.objectId
      } else { throw 'Unrecognized reviewed Easy Auth setup operation.' }
    }
    'EasyAuthConsent' {
      $result.Kind = 'OAuth2PermissionGrant'
      $result.Expected = @{ clientId = $EasyAuth.principalId; resourceId = $Plan.details.inventory.easyAuthGraphResourceId; consentType = 'AllPrincipals' }
      $result.After = @{ scopes = @($Body.scope -split '\s+' | Where-Object { $_ } | Sort-Object -Unique) }
      $result.CoveredByOperationId = Get-MaesterSetupOwnedParent $Session 'EntraServicePrincipal' 'servicePrincipalId' $EasyAuth.principalId
      if ($Operation.method -ceq 'PATCH') {
        $result.Ownership = 'Mutation'; $result.Before = @{ scopes = @($Plan.details.inventory.easyAuthGrant.scope -split '\s+' | Where-Object { $_ } | Sort-Object -Unique) }
        $result.Expected['servicePrincipalId'] = $EasyAuth.principalId
        $result.Expected['applicationObjectId'] = $EasyAuth.objectId
        $result.Expected['appId'] = $EasyAuth.clientId
      }
    }
    'EasyAuthConfiguration' {
      $result.Kind = 'WebAppAuthConfiguration'; $result.Ownership = 'Mutation'
      $result.Expected = @{ webAppResourceId = $Plan.details.inventory.easyAuthWebAppId; appId = $EasyAuth.clientId }
      $result.Before = Get-MaesterWebAuthValues $Plan.details.inventory.easyAuthSettings
      $result.After = Get-MaesterWebAuthValues $Body.properties
    }
    default { throw 'The reviewed setup operation has no ownership journal contract.' }
  }
  if ($result.ContainsKey('CoveredByOperationId') -and ($result.Ownership -cne 'Mutation' -or -not $result.CoveredByOperationId)) { $result.Remove('CoveredByOperationId') }
  return $result
}

function Get-MaesterSetupOperationExactIds {
  param($Ownership, $Operation, $Response, [string]$RequestUri, $EasyAuth)
  switch ($Ownership.Kind) {
    'AzureRoleAssignment' {
      $expectedId = $RequestUri.Split('?')[0]
      if ((Get-MaesterSetupProperty $Response 'id') -ine $expectedId) { throw 'Azure role creation returned no matching exact assignment ID; the ownership operation remains pending.' }
      return @{ roleAssignmentId = [string]$Response.id }
    }
    { $_ -in @('GraphAppRoleAssignment', 'DirectoryRoleAssignment') } {
      return @{ assignmentId = [string](Get-MaesterSetupProperty $Response 'id' '') }
    }
    'ExchangeServicePrincipal' { return @{ exchangeServicePrincipalId = [string](Get-MaesterSetupProperty $Response 'ObjectId' '') } }
    'ExchangeRoleAssignment' { return @{ exchangeRoleAssignmentId = [string](Get-MaesterSetupProperty $Response 'Identity' '') } }
    'EntraApplication' { return @{ applicationObjectId = [string](Get-MaesterSetupProperty $Response 'id' ''); appId = [string](Get-MaesterSetupProperty $Response 'appId' '') } }
    'EntraServicePrincipal' {
      return @{ servicePrincipalId = [string](Get-MaesterSetupProperty $Response 'id' '') }
    }
    'OAuth2PermissionGrant' {
      $id = if ($Operation.method -ceq 'PATCH') { $Operation.uri.Split('/')[-1] } else { Get-MaesterSetupProperty $Response 'id' '' }
      return @{ grantId = [string]$id }
    }
    'ApplicationConfiguration' { return @{ applicationObjectId = [string]$EasyAuth.objectId } }
    'WebAppAuthConfiguration' { return @{ webAppResourceId = [string]$Ownership.Expected.webAppResourceId } }
    default { throw 'The reviewed setup operation has no exact response contract.' }
  }
}

function Assert-MaesterSetupOperationResult {
  param($Ownership, $Operation, $Response, $ExactIds, $ResolvedBody, $PlanParameters)
  # The response IDs have already been durably checkpointed. A contradiction or
  # failed verification must retain those IDs as conflict, never roll them back.
  $observed = $Response
  $fields = @()
  switch ($Ownership.Kind) {
    'GraphAppRoleAssignment' { $fields = @('principalId','resourceId','appRoleId') }
    'DirectoryRoleAssignment' { $fields = @('principalId','roleDefinitionId','directoryScopeId') }
    'AzureRoleAssignment' {
      $observed = Get-MaesterSetupProperty $Response 'properties'
      $fields = @('principalId','roleDefinitionId','principalType')
      $hasScope = if ($observed -is [Collections.IDictionary]) { $observed.Contains('scope') } else { $null -ne $observed -and $null -ne $observed.PSObject.Properties['scope'] }
      if ($hasScope -and (Get-MaesterSetupProperty $observed 'scope') -ine $Ownership.Expected.scope) { throw 'Azure role assignment response does not match the approved scope.' }
    }
    'EntraApplication' {
      $fields = @('displayName')
      if (-not (Test-MaesterSetupDesiredState -Actual $observed -Desired $ResolvedBody)) { throw 'Application creation returned identity tuple or configuration differs from the approved values.' }
    }
    'EntraServicePrincipal' { $fields = @('appId','appOwnerOrganizationId') }
    'ExchangeServicePrincipal' {
      if ((Get-MaesterSetupProperty $Response 'ObjectId') -ine $Ownership.Expected.servicePrincipalId -or (Get-MaesterSetupProperty $Response 'AppId') -ine $Ownership.Expected.appId) { throw 'Exchange returned identity tuple does not match the approved service principal.' }
    }
    'ExchangeRoleAssignment' {
      $matches = @(Get-ManagementRoleAssignment -RoleAssignee $Ownership.Expected.servicePrincipalId -ErrorAction Stop | Where-Object { [string]$_.Identity -ceq $ExactIds.exchangeRoleAssignmentId -and [string]$_.Role -ceq $Ownership.Expected.roleName })
      if ($matches.Count -ne 1) { throw 'Exchange returned identity tuple could not be verified in the exact principal role inventory.' }
    }
    'OAuth2PermissionGrant' {
      if ($Operation.method -ceq 'PATCH') { $observed = Invoke-GraphRestRequest -Method GET -Uri $Operation.uri }
      if ((Get-MaesterSetupProperty $observed 'id') -cne $ExactIds.grantId) { throw 'Delegated grant readback does not match the checkpointed exact grant ID.' }
      if ($Ownership.Expected.consentType -ceq 'AllPrincipals' -and $null -ne (Get-MaesterSetupProperty $observed 'principalId')) { throw 'Delegated grant readback has a principal on an AllPrincipals grant.' }
      $fields = @('clientId','resourceId','consentType')
      $scopes = @(([string](Get-MaesterSetupProperty $observed 'scope' '')) -split '\s+' | Where-Object { $_ } | Sort-Object -Unique)
      if (($scopes -join ' ') -cne (@($Ownership.After.scopes | Sort-Object -Unique) -join ' ')) { throw 'Delegated grant readback does not match the approved scopes.' }
    }
    'ApplicationConfiguration' {
      $observed = Invoke-GraphRestRequest -Method GET -Uri $Operation.uri
      if ((Get-MaesterSetupProperty $observed 'id') -ine $ExactIds.applicationObjectId -or (Get-MaesterSetupProperty $observed 'appId') -ine $Ownership.Expected.appId -or -not (Test-MaesterSetupDesiredState -Actual $observed -Desired $ResolvedBody)) { throw 'Application configuration readback does not match the approved exact target and values.' }
    }
    'WebAppAuthConfiguration' {
      $observed = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$($Operation.uri)" -Headers $PlanParameters.ArmHeaders
      if (-not (Test-MaesterSetupDesiredState -Actual $observed -Desired $ResolvedBody)) { throw 'Web App authentication readback does not match the approved values.' }
    }
  }
  foreach ($field in $fields) {
    $value = Get-MaesterSetupProperty $observed $field
    if ($null -eq $value -or [string]$value -ine [string]$Ownership.Expected[$field]) { throw "Provider returned identity tuple differs from the approved $field." }
  }
}

function Get-MaesterSetupLegacyReceipts {
  param($Session, [string]$PrincipalObjectId)
  $receipts = @{ EXO_APPROLE_ASSIGNMENT_IDS = @(); TEAMS_READER_ROLE_ASSIGNMENT_IDS = @(); AZURE_ROLE_ASSIGNMENT_IDS = @() }
  foreach ($record in @((Get-MaesterOwnershipJournal -Session $Session).records)) {
    if ($record.ownership -cne 'Created' -or $record.state -cne 'applied' -or (Get-MaesterSetupProperty $record.expected 'principalId') -ine $PrincipalObjectId) { continue }
    if ($record.kind -ceq 'GraphAppRoleAssignment' -and $record.expected.appRoleId -ceq 'dc50a0fb-09a3-484d-be87-e023b12c6440') { $receipts.EXO_APPROLE_ASSIGNMENT_IDS += $record.exactIds.assignmentId }
    elseif ($record.kind -ceq 'DirectoryRoleAssignment') { $receipts.TEAMS_READER_ROLE_ASSIGNMENT_IDS += $record.exactIds.assignmentId }
    elseif ($record.kind -ceq 'AzureRoleAssignment') { $receipts.AZURE_ROLE_ASSIGNMENT_IDS += $record.exactIds.roleAssignmentId }
  }
  return $receipts
}

function Invoke-MaesterSetupAccessPlan {
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$PlanParameters, [Parameter(Mandatory)][string]$ApprovedPlanHash, $OwnershipSession)
  # The entrypoint holds the lifecycle lock and revalidates ARM targets before
  # entering this fresh authority inventory. Plan-only callers never open it.
  $plan = Get-MaesterSetupAccessPlan @PlanParameters
  if ($ApprovedPlanHash -cne $plan.planHash) { throw 'Setup access changed after review. Generate and approve the new plan before applying.' }
  Assert-MaesterConsentPlanApproval -Plan $plan -ApprovedPlanHash $ApprovedPlanHash
  if ($null -eq $OwnershipSession) { throw 'An open deployment ownership journal session is required before setup writes.' }
  $journal = Get-MaesterOwnershipJournal -Session $OwnershipSession
  if ($journal.binding.tenantId -ine $PlanParameters.TenantId -or $journal.binding.subscriptionId -ine $PlanParameters.SubscriptionId -or
      $journal.binding.setupClientId -ine $plan.details.setupClientId -or $journal.binding.runtimeResourceId -ine $PlanParameters.ResourceId -or
      $journal.binding.runtimePrincipalId -ine $PlanParameters.PrincipalObjectId) { throw 'Setup ownership journal does not match the reviewed deployment target.' }
  if (@($journal.records | Where-Object { $_.state -in @('pending', 'deleting', 'conflict') }).Count) { throw 'Unresolved ownership operations require exact reconciliation before further setup writes.' }
  $graphPlan = $plan.details.graphPlan
  $grantScript = Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Grant-MaesterGraphPermissions.ps1'
  $null = & $grantScript -TenantId $PlanParameters.TenantId -PrincipalObjectId $PlanParameters.PrincipalObjectId `
    -PermissionProfile $PlanParameters.PermissionProfile -IncludeMailSend $PlanParameters.IncludeMailSend `
    -IncludeReportSettingsWrite $PlanParameters.IncludeReportSettingsWrite -Apply -ApprovedPlanHash $graphPlan.planHash -OwnershipSession $OwnershipSession
  # Keep the reviewed, hashed plan immutable; resolved IDs are execution output.
  $easyAuth = if ($plan.details.easyAuth) { $plan.details.easyAuth | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable } else { $null }
  foreach ($plannedOperation in @($plan.details.operations)) {
    $operation = $plannedOperation | ConvertTo-Json -Depth 30 -Compress | ConvertFrom-Json -AsHashtable
    $body = $operation.body | ConvertTo-Json -Depth 30 -Compress
    if ($easyAuth) { $body = $body.Replace('{easyAuthClientId}', [string]$easyAuth.clientId).Replace('{easyAuthPrincipalId}', [string]$easyAuth.principalId) }
    if ($body -match '\{easyAuth(Client|Principal)Id\}') { throw 'Easy Auth creation did not return the expected exact identifiers.' }
    $resolvedBody = $body | ConvertFrom-Json -AsHashtable
    $ownership = Get-MaesterSetupOperationOwnership -Session $OwnershipSession -Operation $operation -Body $resolvedBody -Plan $plan -EasyAuth $easyAuth
    $operationKey = 'setup-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($plannedOperation | ConvertTo-Json -Depth 30 -Compress)))).ToLowerInvariant()
    # ARM assignment names are fixed before the request, so a failed response
    # still leaves the exact intended target. Unknown POST results stay pending.
    $requestUri = $operation.uri.Replace('{assignmentId}', [guid]::NewGuid().ToString())
    if ($ownership.Kind -ceq 'AzureRoleAssignment') { $ownership.Expected['roleAssignmentId'] = $requestUri.Split('?')[0] }
    $ownedOperation = Start-MaesterOwnedOperation -Session $OwnershipSession -Key $operationKey -PlanHash $plan.planHash @ownership
    $response = $null
    switch ($operation.method) {
      'New-ServicePrincipal' { $response = New-ServicePrincipal @resolvedBody -ErrorAction Stop }
      'New-ManagementRoleAssignment' { $response = New-ManagementRoleAssignment @resolvedBody -ErrorAction Stop }
      default {
        if ($requestUri.StartsWith('https://graph.microsoft.com/')) {
          $response = Invoke-GraphRestRequest -Method $operation.method -Uri $requestUri -Body $body -ContentType 'application/json'
        } else {
          $response = Invoke-RestMethod -Method $operation.method -Uri "https://management.azure.com$requestUri" -Headers $PlanParameters.ArmHeaders -Body $body -ContentType 'application/json'
        }
      }
    }
    $exactIds = Get-MaesterSetupOperationExactIds -Ownership $ownership -Operation $operation -Response $response -RequestUri $requestUri -EasyAuth $easyAuth
    Complete-MaesterOwnedOperation -Session $OwnershipSession -OperationId $ownedOperation.operationId -ExactIds $exactIds | Out-Null
    try {
      Assert-MaesterSetupOperationResult -Ownership $ownership -Operation $operation -Response $response -ExactIds $exactIds -ResolvedBody $resolvedBody -PlanParameters $PlanParameters
    } catch {
      Set-MaesterOwnedOperationState -Session $OwnershipSession -OperationId $ownedOperation.operationId -State conflict | Out-Null
      throw
    }
    switch ($operation.receipt) {
      'EasyAuthApplication' { $easyAuth.objectId = $exactIds.applicationObjectId; $easyAuth.clientId = $exactIds.appId }
      'EasyAuthPrincipal' { $easyAuth.principalId = $exactIds.servicePrincipalId }
    }
  }
  # Compatibility summaries are derived from all persisted owned entries, never
  # just this invocation's delta. A no-op rerun cannot erase earlier ownership.
  $receipts = Get-MaesterSetupLegacyReceipts -Session $OwnershipSession -PrincipalObjectId $PlanParameters.PrincipalObjectId
  [pscustomobject]@{ Plan = $plan; Receipts = $receipts; EasyAuth = $easyAuth; PrincipalDisplayName = $plan.details.inventory.principal.displayName }
}

Export-ModuleMember -Function Get-MaesterSetupAccessPlan, Invoke-MaesterSetupAccessPlan
