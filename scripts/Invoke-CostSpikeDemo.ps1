#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateSet('GBP')][string]$BillingCurrency,
    [ValidateSet('Inspect', 'Prepare', 'Start', 'Status', 'Restore', 'Cleanup')][string]$Phase = 'Inspect',
    [string[]]$NotificationEmails = @(),
    [switch]$AcknowledgeIntentionalSpend,
    [decimal]$ReviewedBudgetAmount = 0
)
. (Join-Path $PSScriptRoot 'CostSpike.Common.ps1')
if ($BillingCurrency -ne 'GBP') { throw 'Only the approved GBP scenario is supported.' }
Assert-Subscription $SubscriptionId
$scope = "/subscriptions/$SubscriptionId"
$accountId = "$scope/resourceGroups/rg-finops-development/providers/Microsoft.Automation/automationAccounts/contoso-cost-spike"
$root = Split-Path $PSScriptRoot
$inventory = Get-SpikeInventory
$accounts = Invoke-AzJson @('resource', 'list', '--subscription', $SubscriptionId, '-g', 'rg-finops-development',
    '--resource-type', 'Microsoft.Automation/automationAccounts')
$account = @($accounts | Where-Object { $_.id -eq $accountId })
if ($account.Count -and ($account[0].tags.Project -ne 'ContosoFinOpsDemo' -or
    $account[0].tags.Application -ne 'CostSpikeGuardrail')) { throw 'Automation account name belongs to an unrelated resource.' }
$state = if ($account.Count) { Get-SpikeState } else { $null }

if ($Phase -eq 'Status') {
    $inventory.plans | Select-Object name, sku, @{n='RunOwner'; e={$_.tags['CostSpikeRun']}}
    if ($null -ne $state) {
        $state | Select-Object runId, status, startedAtUtc, rollbackAtUtc, estimate, budget
        (Invoke-SpikeArm GET "$accountId/jobs").value | Select-Object name, properties
        (Invoke-SpikeArm GET "$accountId/schedules").value | Select-Object name, properties
        Write-Output 'Use Azure Cost Analysis and Turbo360 actual-cost imports to verify billed spend and delivered alerts.'
    } else { Write-Output 'No prepared cost-spike state.' }
    return
}
if ($Phase -in @('Inspect', 'Prepare', 'Start')) {
    Assert-SpikeBaseline $inventory.plans
    $estimate = Get-SpikeEstimate $inventory.plans[0].location
    $budget = Get-SpikeBudgetPreview $inventory.plans $estimate
    Write-Output ($estimate | ConvertTo-Json)
    Write-Output ($budget | ConvertTo-Json)
    Write-Warning 'Deliberately incurred demo spend; 20-hour automatic rollback is not a hard spending cap. Both plans may restart apps.'
    if ($Phase -eq 'Inspect') { return }
    if ($NotificationEmails.Count -eq 0) { throw 'Supply explicit notification emails.' }
    foreach ($email in $NotificationEmails) { [void][System.Net.Mail.MailAddress]::new($email) }
}

if ($Phase -eq 'Prepare') {
    if ($state) { throw 'Existing demo state found. Use Status/Restore/Cleanup before preparing another run.' }
    Assert-SpikeConnectivity $inventory
    $locations = Invoke-AzJson @('appservice', 'list-locations', '--subscription', $SubscriptionId, '--sku', 'S3', '--linux-workers-enabled')
    if (-not ($locations | Where-Object { ($_.name -replace '\s', '').ToLowerInvariant() -eq $estimate.region })) {
        throw 'Regional S3 availability was not confirmed; no automatic SKU fallback.'
    }
    $budgets = Invoke-AzJson @('consumption', 'budget', 'list', '--subscription', $SubscriptionId)
    if ($budgets | Where-Object { $_.name -eq 'contoso-cost-spike' }) { throw 'Demo budget name already exists; review it before preparing.' }
    $actions = Invoke-SpikeArm GET "$scope/providers/Microsoft.CostManagement/scheduledActions" -Api '2025-03-01'
    $anomaly = @($actions.value | Where-Object {
        $_.kind -eq 'InsightAlert' -and $_.properties.viewId -like '*ms:DailyAnomalyByResourceGroup' -and $_.properties.status -eq 'Enabled'
    })
    if ($actions.value | Where-Object { $_.name -eq 'contoso-cost-spike-anomaly' }) {
        throw 'Demo anomaly alert name already exists. Review ownership before preparing.'
    }
    $actionGroups = Invoke-AzJson @('monitor', 'action-group', 'list', '--subscription', $SubscriptionId, '-g', 'rg-finops-shared')
    $emailGroup = @($actionGroups | Where-Object { $_.tags.Project -eq 'ContosoFinOpsDemo' -and $_.enabled -and $_.emailReceivers.Count -gt 0 })
    if ($emailGroup.Count -ne 1) { throw 'Exactly one enabled project email action group is required for rollback failures.' }
    if (-not $PSCmdlet.ShouldProcess($SubscriptionId, 'Prepare narrowly scoped Automation, failure alert and native anomaly notifications; do not resize')) { return }
    $parameters = @{
        location = $estimate.region; developmentPlanName = $inventory.plans[0].name; productionPlanName = $inventory.plans[1].name
        tags = (@{} + $inventory.plans[0].tags)
        actionGroupId = $emailGroup[0].id
    }
    $parameters.tags.Application = 'CostSpikeGuardrail'
    $parameters.tags.ManagedBy = 'Bicep'
    $file = Join-Path ([IO.Path]::GetTempPath()) "cost-spike-parameters-$([guid]::NewGuid()).json"
    try {
        $values = @{}
        foreach ($key in $parameters.Keys) { $values[$key] = @{ value = $parameters[$key] } }
        @{ parameters = $values } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $file
        $deployment = Invoke-AzJson @('deployment', 'sub', 'create', '--subscription', $SubscriptionId,
            '--location', $estimate.region, '--name', 'contoso-cost-spike-guardrail',
            '--template-file', (Join-Path $root 'infra/modules/cost-spike-automation.bicep'), '--parameters', "@$file")
        if ($deployment.properties.provisioningState -ne 'Succeeded') { throw 'Guardrail deployment failed.' }
    } finally { Remove-Item -LiteralPath $file }
    $state = @{
        project = 'ContosoFinOpsDemo'; runId = [guid]::NewGuid().ToString(); subscriptionId = $SubscriptionId; status = 'Prepared'
        plans = @($inventory.plans | ForEach-Object {
            @{ id = $_.id; baselineSku = 'B1'; baselineCapacity = 1; targetSku = 'S3'; targetCapacity = 1 }
        })
        estimate = $estimate; budget = $budget; schedules = @()
        cleanupIds = $deployment.properties.outputs.cleanupIds.value
        ownsAnomaly = $false; ownsBudget = $false
    }
    Invoke-SpikeStateWrite $state
    [void](Invoke-Az @('rest', '--subscription', $SubscriptionId, '--method', 'put',
        '--url', "https://management.azure.com$accountId/runbooks/Restore-CostSpike/draft/content?api-version=2024-10-23",
        '--headers', 'Content-Type=text/plain', '--body', "@$(Join-Path $PSScriptRoot 'automation/Restore-CostSpike.ps1')"))
    $uploaded = $false
    $expectedContent = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'automation/Restore-CostSpike.ps1') -Raw).TrimEnd()
    for ($poll = 0; $poll -lt 30; $poll++) {
        $content = Invoke-Az @('rest', '--subscription', $SubscriptionId, '--method', 'get',
            '--url', "https://management.azure.com$accountId/runbooks/Restore-CostSpike/draft/content?api-version=2024-10-23")
        if ($content.TrimEnd() -eq $expectedContent) { $uploaded = $true; break }
        Start-Sleep -Seconds 10
    }
    if (-not $uploaded) { throw 'Uploaded runbook content could not be verified. No scale-up is allowed.' }
    [void](Invoke-Az @('rest', '--subscription', $SubscriptionId, '--method', 'post',
        '--url', "https://management.azure.com$accountId/runbooks/Restore-CostSpike/publish?api-version=2024-10-23"))
    $published = $false
    for ($poll = 0; $poll -lt 30; $poll++) {
        $book = Invoke-SpikeArm GET "$accountId/runbooks/Restore-CostSpike"
        if ($book.properties.state -eq 'Published') { $published = $true; break }
        Start-Sleep -Seconds 10
    }
    if (-not $published) { throw 'Runbook publication was not verified.' }
    $state.verificationJobId = Invoke-SpikeVerificationJob $state
    if ($anomaly.Count -eq 0) {
        $state.ownsAnomaly = $true
        Invoke-SpikeStateWrite $state
        [void](Invoke-SpikeArm PUT "$scope/providers/Microsoft.CostManagement/scheduledActions/contoso-cost-spike-anomaly" @{
            kind = 'InsightAlert'
            properties = @{
                displayName = 'Contoso cost spike native anomaly'
                status = 'Enabled'; viewId = "$scope/providers/Microsoft.CostManagement/views/ms:DailyAnomalyByResourceGroup"
                notification = @{ subject = 'Native Azure cost anomaly detected (not a demo budget)'; to = $NotificationEmails }
                schedule = @{ frequency = 'Daily'; startDate = [DateTimeOffset]::UtcNow.ToString('o'); endDate = [DateTimeOffset]::UtcNow.AddMonths(2).ToString('o') }
            }
        } -Api '2025-03-01')
    } else { Write-Output 'Existing native anomaly alert preserved; verify its recipients in Azure.' }
    Invoke-SpikeStateWrite $state
    Write-Output 'Guardrail prepared and read-only runbook verification completed. No plans were resized. Run Inspect again before Start.'
    return
}
if ($null -eq $state) { throw 'Prepare the guardrail first. No durable recovery state exists.' }
Assert-SpikeState $state
if ((@($state.plans.id | Sort-Object) -join ',') -ne (@($inventory.plans.id | Sort-Object) -join ',')) {
    throw 'Live plan bindings differ from durable recovery state.'
}
$localRequest = { param($method, $id, $body) Invoke-SpikeArm $method $id $body -Api '2025-03-01' }
if ($Phase -eq 'Start') {
    if ($state.status -ne 'Prepared' -or -not $state.ContainsKey('verificationJobId')) { throw 'Run already armed or guardrail verification incomplete; use Restore/Cleanup.' }
    if (-not $AcknowledgeIntentionalSpend -or $ReviewedBudgetAmount -ne $budget.amountNetGbp) {
        throw "Acknowledge the deliberate spend and pass -ReviewedBudgetAmount $($budget.amountNetGbp) from a current Inspect preview."
    }
    Wait-SpikeJob $state.verificationJobId
    $runbook = Invoke-SpikeArm GET "$accountId/runbooks/Restore-CostSpike"
    if ($runbook.properties.state -ne 'Published') { throw 'Rollback runbook is no longer published.' }
    Assert-SpikeConnectivity $inventory
    if (-not $PSCmdlet.ShouldProcess($SubscriptionId, 'Arm verified 20-hour rollback, create demo budget, and resize BOTH B1 plans to S3/one worker')) { return }
    $state.verificationJobId = Invoke-SpikeVerificationJob $state
    $state.estimate = $estimate; $state.budget = $budget
    $state.startedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $state.rollbackAtUtc = [DateTimeOffset]::UtcNow.AddHours(20).ToString('o')
    $state.status = 'Armed'
    Invoke-SpikeStateWrite $state
    try {
        $deadline = [DateTimeOffset]$state.rollbackAtUtc
        $state.schedules += Invoke-SpikeScheduleCreation $state "Restore-$($state.runId)" $deadline
        Invoke-SpikeStateWrite $state
        $state.schedules += Invoke-SpikeScheduleCreation $state "Retry-$($state.runId)" $deadline.AddHours(1) -Recurring
        Invoke-SpikeStateWrite $state
        $state.ownsBudget = $true
        Invoke-SpikeStateWrite $state
        Invoke-SpikeBudgetCreation $state $NotificationEmails
        $owner = Get-SpikeState
        if ($owner.runId -ne $state.runId -or $owner.status -ne 'Armed') { throw 'Durable run ownership changed; refusing concurrent execution.' }
        foreach ($plan in $state.plans) {
            if ([DateTimeOffset]::UtcNow -ge $deadline.AddHours(-1)) { throw 'Start took too long; aborting before the rollback window.' }
            Invoke-SpikeScaleUp $plan $state.runId
            Assert-SpikeConnectivity (Get-SpikeInventory)
        }
        $state.status = 'Active'; Invoke-SpikeStateWrite $state
    } catch {
        $failure = $_.Exception.Message
        Write-Warning "Start failed: $failure. Attempting immediate restoration of both plans; durable retries remain armed."
        try {
            Invoke-SpikeRestoration $state -Request $localRequest
            $state.status = 'Restored'; Invoke-SpikeStateWrite $state
        } catch { throw "Start failed: $failure. Recovery also failed: $($_.Exception.Message). Inspect Automation and run Restore immediately." }
        throw "Start failed and baseline was restored: $failure"
    }
    $evidenceDirectory = Join-Path $root '.artifacts/cost-spike'
    [void](New-Item -ItemType Directory -Path $evidenceDirectory -Force)
    $state | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $evidenceDirectory "$($state.runId).json")
    Write-Output "Verified both plans on S3/one worker. Rollback UTC: $($state.rollbackAtUtc). Check Status and actual billing data later."
    return
}
if ($Phase -eq 'Restore') {
    if (-not $PSCmdlet.ShouldProcess($SubscriptionId, 'Restore both exact demo-owned plans to B1/one worker; retain retry schedules')) { return }
    Invoke-SpikeRestoration $state -Request $localRequest
    $state.status = 'Restored'; Invoke-SpikeStateWrite $state
    Assert-SpikeConnectivity (Get-SpikeInventory)
    Write-Output 'Both plans and app connectivity verified at baseline. Cleanup after saving cost/alert evidence.'
    return
}
if ($Phase -eq 'Cleanup') {
    Assert-SpikeBaseline $inventory.plans
    Assert-SpikeCleanup $state
    if (-not $PSCmdlet.ShouldProcess($SubscriptionId, 'Delete only demo guardrail resources and demo-owned alerts/budget AFTER exporting evidence')) { return }
    foreach ($plan in $inventory.plans) { Assert-SpikeBaseline @((Get-SpikePlan $plan.id)) }
    if ($state.ownsBudget) {
        [void](Invoke-Az @('rest', '--subscription', $SubscriptionId, '--method', 'delete',
            '--url', "https://management.azure.com$scope/providers/Microsoft.Consumption/budgets/contoso-cost-spike?api-version=2024-08-01"))
    }
    if ($state.ownsAnomaly) {
        [void](Invoke-Az @('rest', '--subscription', $SubscriptionId, '--method', 'delete',
            '--url', "https://management.azure.com$scope/providers/Microsoft.CostManagement/scheduledActions/contoso-cost-spike-anomaly?api-version=2025-03-01"))
    }
    foreach ($id in @($state.cleanupIds | Where-Object { $_ -ne $accountId }) + @($accountId)) {
        if ($id -in $state.plans.id -or ($id -notlike "$scope/*")) { throw 'Invalid guardrail cleanup scope.' }
        $api = if ($id -match '/roleAssignments/|/roleDefinitions/') { '2022-04-01' }
            elseif ($id -match '/metricAlerts/') { '2026-01-01' } else { '2024-10-23' }
        [void](Invoke-Az @('rest', '--subscription', $SubscriptionId, '--method', 'delete',
            '--url', "https://management.azure.com${id}?api-version=$api"))
    }
    $removed = $false
    for ($poll = 0; $poll -lt 30; $poll++) {
        $remaining = Invoke-AzJson @('resource', 'list', '--subscription', $SubscriptionId, '-g', 'rg-finops-development',
            '--resource-type', 'Microsoft.Automation/automationAccounts')
        if (-not ($remaining | Where-Object { $_.id -eq $accountId })) { $removed = $true; break }
        Start-Sleep -Seconds 10
    }
    if (-not $removed) { throw 'Automation account deletion did not complete; inspect residual schedules and resources.' }
    Write-Output 'Demo guardrails removed. Plans/apps/databases and existing budgets were not deleted. Verify final billing after ingestion.'
}
