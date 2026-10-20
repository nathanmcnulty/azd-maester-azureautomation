BeforeAll {
  $repoRoot = Split-Path $PSScriptRoot -Parent
  $probePath = Join-Path $PSScriptRoot 'fixtures/Invoke-NativeSetupConsent.ps1'
  $pwshPath = (Get-Process -Id $PID).Path
  function Invoke-NativeSetupProbe {
    param([string]$Mode = 'Plan', [string]$ApprovedPlanHash)
    $project = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    $null = New-Item -ItemType Directory $project
    Copy-Item (Join-Path $repoRoot 'scripts'), (Join-Path $repoRoot 'infra') $project -Recurse
    $result = Join-Path $project 'probe.json'
    & $pwshPath -NoProfile -NonInteractive -File $probePath -ProjectRoot $project -ResultPath $result -Mode $Mode -ApprovedPlanHash $ApprovedPlanHash
    $LASTEXITCODE | Should -Be 0
    Get-Content $result -Raw | ConvertFrom-Json
  }
}

Describe 'Actual native Automation setup approval and import scopes (offline)' {
  It 'retains real approval and helper commands through nested canonical planning and immediate ownership import' {
    # Each call has a fresh pwsh process, real entrypoint, real planner, canonical
    # Grant script and real modules. Never mock Import-Module or approval commands.
    $dry = Invoke-NativeSetupProbe
    $dry.Error | Should -BeExactly ''
    $dry.Writes.Count | Should -Be 0
    $dry.LocalFilesUnchanged | Should -BeTrue
    $dry.Marker | Should -BeFalse
    $dry.Journal | Should -BeNullOrEmpty
    $plan = $dry.Plan
    $plan.planHash | Should -Match '^[a-f0-9]{64}$'
    $plan.details.graphPlan.desired.Count | Should -Be 27
    $plan.details.graphPlan.missing.Count | Should -Be 27
    $plan.missing.Count | Should -Be 28
    $plan.details.operations.Count | Should -Be 1
    $plan.details.operations[0].category | Should -BeExactly 'StorageReader'
    $plan.details.operations[0].body.properties.principalId | Should -BeExactly $dry.Operator
    $plan.details.operations[0].body.properties.principalType | Should -BeExactly 'User'
    foreach ($option in 'includeExchange', 'includeTeams', 'includeAzure', 'includeMailSend', 'includeReportSettingsWrite') { $plan.details.$option | Should -BeFalse }
    $plan.details.easyAuth | Should -BeNullOrEmpty
    (Invoke-NativeSetupProbe).Plan.planHash | Should -BeExactly $plan.planHash

    $rejected = Invoke-NativeSetupProbe -Mode Apply -ApprovedPlanHash ('0' * 64)
    $rejected.Error | Should -BeLike 'Permission expansion requires approval of the current plan hash*'
    $rejected.ErrorType | Should -BeExactly 'System.Management.Automation.RuntimeException'
    $rejected.Writes.Count | Should -Be 0
    $rejected.LocalFilesUnchanged | Should -BeTrue
    $rejected.Marker | Should -BeFalse
    $rejected.Journal | Should -BeNullOrEmpty
    $rejected.ReadsAfterApproval.Count | Should -Be 0

    $approved = Invoke-NativeSetupProbe -Mode Apply -ApprovedPlanHash $plan.planHash
    # Only this exact provider sentinel is success, never an arbitrary exception.
    $approved.Error | Should -BeExactly 'NATIVE_SETUP_FIRST_GRAPH_WRITE'
    $approved.ErrorType | Should -BeExactly 'System.InvalidOperationException'
    $approved.Writes.Count | Should -Be 1
    $approved.Writes[0] | Should -BeExactly "POST https://graph.microsoft.com/v1.0/servicePrincipals/$($dry.Principal)/appRoleAssignments"
    $approved.Marker | Should -BeTrue
    # The verified setup session survives InfrastructureOwnership's immediate
    # dependency import; subsequent provider calls still use real context checks.
    $approved.Logins | Should -Be 0
    $approved.ClientChecks | Should -Be 1
    $approved.ClientChecksAfterApproval | Should -Be 0
    $approved.ContextChecksAfterApproval | Should -BeGreaterThan 0
    $approved.Journal.binding.runtimePrincipalId | Should -BeExactly $dry.Principal
    $approved.Journal.records.Count | Should -Be 1
    $approved.Journal.records[0].kind | Should -BeExactly 'GraphAppRoleAssignment'
    $approved.Journal.records[0].state | Should -BeExactly 'pending'
    $approved.Journal.records[0].planHash | Should -BeExactly $plan.details.graphPlanHash
    foreach ($target in @($dry.Storage.id, $dry.Account.id, "$($dry.Account.id)/jobSchedules", "$($dry.Account.id)/schedules", "$($dry.Account.id)/runbooks")) {
      @($approved.ReadsAfterApproval | Where-Object { $_.Split('?')[0] -ceq "https://management.azure.com$target" }).Count | Should -BeGreaterThan 0
    }
  }
}
