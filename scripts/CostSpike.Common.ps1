#Requires -Version 7.2
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'automation/Restore-CostSpike.ps1')

function Invoke-SpikeArm {
    param([string]$Method, [string]$Id, [hashtable]$Body, [string]$Api = '2024-10-23')
    $arguments = @('rest', '--subscription', $SubscriptionId, '--method', $Method,
        '--url', "https://management.azure.com${Id}?api-version=$Api")
    if ($null -eq $Body) { return Invoke-AzJson $arguments }
    $file = Join-Path ([IO.Path]::GetTempPath()) "cost-spike-$([guid]::NewGuid()).json"
    try {
        $Body | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $file -WhatIf:$false
        Invoke-AzJson ($arguments + @('--body', "@$file"))
    } finally {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -WhatIf:$false }
    }
}

function Get-SpikePlan {
    param([string]$Id)
    Invoke-SpikeArm GET $Id -Api '2025-03-01'
}

function Get-SpikeInventory {
    $estate = Get-Estate $SubscriptionId
    $apps = @()
    foreach ($app in @($estate.developmentApplication) + @($estate.productionApplications)) {
        $apps += Invoke-SpikeArm GET $app.resourceId -Api '2025-03-01'
    }
    $plans = @()
    foreach ($group in @('rg-finops-development', 'rg-finops-shared')) {
        $bindings = @($apps | Where-Object {
            if ($group -eq 'rg-finops-development') { $_.tags.Environment -eq 'Development' }
            else { $_.tags.Environment -eq 'Production' }
        } | ForEach-Object { $_.properties.serverFarmId } | Sort-Object -Unique)
        if ($bindings.Count -ne 1 -or $bindings[0] -notlike "*/resourceGroups/$group/providers/Microsoft.Web/serverfarms/*") {
            throw "Unexpected application plan bindings for $group."
        }
        $plan = Get-SpikePlan $bindings[0]
        if ($plan.tags.Project -ne 'ContosoFinOpsDemo' -or -not $plan.properties.reserved -or
            $plan.properties.zoneRedundant -or $plan.properties.perSiteScaling) {
            throw "Unexpected plan ownership/Linux/scaling settings: $($plan.id)"
        }
        $plans += $plan
    }
    if ($plans[0].location -ne $plans[1].location) { throw 'Both plans must be in the same reviewed region.' }
    @{ estate = $estate; apps = $apps; plans = $plans }
}

function Assert-SpikeBaseline {
    param([object[]]$Plans)
    foreach ($plan in $Plans) {
        if ($plan.sku.name -ne 'B1' -or $plan.sku.capacity -ne 1 -or $plan.tags['CostSpikeRun'] -or
            $plan.properties.provisioningState -ne 'Succeeded') {
            throw "An unowned, succeeded B1/one-worker baseline is required: $($plan.id). Use Status/Restore for an existing run."
        }
    }
}

function Get-SpikeEstimate {
    param([string]$Region)
    if ($Region -cnotmatch '^[a-z][a-z0-9]+$') { throw 'Pricing requires an ARM region code.' }
    $filter = [uri]::EscapeDataString("armRegionName eq '$Region' and priceType eq 'Consumption' and serviceName eq 'Azure App Service'")
    $url = "https://prices.azure.com/api/retail/prices?currencyCode=GBP&`$filter=$filter"
    $items = @()
    while ($url) {
        $page = Invoke-RestMethod -Uri $url -TimeoutSec 60
        $items += @($page.Items)
        $url = $page.NextPageLink
    }
    $rates = @{}
    foreach ($sku in @('B1', 'S3')) {
        $product = if ($sku -eq 'B1') { 'Azure App Service Basic Plan - Linux' } else { 'Azure App Service Standard Plan - Linux' }
        $meters = @($items | Where-Object {
            $_.skuName -eq $sku -and $_.productName -eq $product -and $_.unitOfMeasure -eq '1 Hour' -and
            $_.currencyCode -eq 'GBP' -and $_.tierMinimumUnits -eq 0 -and $_.retailPrice -gt 0
        })
        if ($meters.Count -ne 1) { throw "Expected exactly one current GBP consumption rate for $sku in $Region." }
        $rates[$sku] = [decimal]$meters[0].retailPrice
    }
    $increment = 2 * ($rates.S3 - $rates.B1)
    if ($increment -le 0) { throw 'S3 does not produce the expected price increase.' }
    $estimate = @{
        region = $Region; b1HourlyNet = $rates.B1; s3HourlyNet = $rates.S3
        additional20HoursGross = [math]::Round($increment * 20 * [decimal]1.2, 2)
        additional24HoursGross = [math]::Round($increment * 24 * [decimal]1.2, 2)
        automationReserveGross = 2
        allowanceGross = 20
        pricedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if ($increment * 24 * [decimal]1.2 + $estimate.automationReserveGross -gt 20) {
        throw '24-hour additional compute plus GBP 2 Automation reserve exceeds the approved GBP 20 allowance.'
    }
    $estimate
}

function Get-SpikeBudgetPreview {
    param([object[]]$Plans, [hashtable]$Estimate, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    $now = $Now
    if ($now.AddHours(24).Month -ne $now.Month) { throw 'Do not start across a month boundary; rerun Inspect next month.' }
    $scope = "/subscriptions/$SubscriptionId"
    $query = Invoke-SpikeArm POST "$scope/providers/Microsoft.CostManagement/query" @{
        type = 'ActualCost'; timeframe = 'MonthToDate'
        dataset = @{
            granularity = 'Daily'
            aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
            filter = @{ dimensions = @{ name = 'ResourceId'; operator = 'In'; values = @($Plans.id) } }
        }
    } -Api '2025-03-01'
    $columns = @($query.properties.columns.name)
    $costIndex = [Array]::IndexOf($columns, 'Cost')
    $dateIndex = [Array]::IndexOf($columns, 'UsageDate')
    $currencyIndex = [Array]::IndexOf($columns, 'Currency')
    if ($costIndex -lt 0 -or $dateIndex -lt 0 -or $currencyIndex -lt 0 -or
        $null -eq $query.properties.rows -or @($query.properties.rows).Count -eq 0) { throw 'Missing billed baseline cost data. Wait for ingestion; no zero-cost fallback is used.' }
    $total = [decimal]0
    $lastDate = [DateTimeOffset]::MinValue
    foreach ($row in $query.properties.rows) {
        if ($row[$currencyIndex] -ne 'GBP' -or $null -eq $row[$costIndex]) { throw 'Cost data must have explicit GBP amounts.' }
        $total += [decimal]$row[$costIndex]
        $date = [DateTimeOffset]::ParseExact([string]$row[$dateIndex], 'yyyyMMdd', [cultureinfo]::InvariantCulture)
        if ($date -gt $lastDate) { $lastDate = $date }
    }
    if (($now - $lastDate).TotalHours -gt 96 -or $total -le 0) { throw 'Billed baseline is stale or nonpositive; wait for valid cost data.' }
    $pendingHours = [math]::Max(0, ($now - $lastDate).TotalHours)
    if ($lastDate -gt $now -or $lastDate.Month -ne $now.Month -or $lastDate.Year -ne $now.Year) {
        throw 'Cost rows are outside the current billing month.'
    }
    $pending = 2 * $Estimate.b1HourlyNet * ($pendingHours + 24)
    $halfSpike = ($Estimate.additional20HoursGross / [decimal]1.2) / 2
    @{
        amountNetGbp = [math]::Round($total + $pending + $halfSpike, 2)
        observedMonthToDateNetGbp = $total
        lastUsageDateUtc = $lastDate.ToString('o')
        month = $now.ToString('yyyy-MM')
    }
}

function Assert-SpikeConnectivity {
    param([hashtable]$Inventory)
    foreach ($role in @('DevelopmentPortal', 'OrdersAPI')) {
        $app = @($Inventory.apps | Where-Object { $_.tags.Application -eq $role })[0]
        $dev = $role -eq 'DevelopmentPortal'
        $group = if ($dev) { 'rg-finops-development' } else { 'rg-finops-production' }
        $server = if ($dev) { $Inventory.estate.sqlServers.development } else { $Inventory.estate.sqlServers.production }
        $rules = Invoke-AzJson @('sql', 'server', 'firewall-rule', 'list', '--subscription', $SubscriptionId,
            '-g', $group, '-s', $server)
        $possible = @($app.properties.possibleOutboundIpAddresses.Split(',', [StringSplitOptions]::RemoveEmptyEntries))
        if (-not $possible.Count) { throw "No possible egress addresses for $role." }
        foreach ($ip in $possible) {
            Assert-Address $ip
            if (-not ($rules | Where-Object { $_.startIpAddress -eq $ip -and $_.endIpAddress -eq $ip })) {
                throw "SQL does not permit possible $role egress $ip. Review Network phase; no rules will be widened by this script."
            }
        }
    }
    $api = @($Inventory.apps | Where-Object { $_.tags.Application -eq 'OrdersAPI' })[0]
    $config = Invoke-AzJson @('webapp', 'config', 'access-restriction', 'show', '--subscription', $SubscriptionId,
        '-g', 'rg-finops-production', '-n', $api.name)
    foreach ($portal in $Inventory.apps | Where-Object { $_.tags.Application -in @('CustomerPortal', 'ReportingPortal') }) {
        foreach ($ip in $portal.properties.possibleOutboundIpAddresses.Split(',', [StringSplitOptions]::RemoveEmptyEntries)) {
            Assert-Address $ip
            if (-not ($config.ipSecurityRestrictions | Where-Object { $_.action -eq 'Allow' -and $_.ipAddress -eq "$ip/32" })) {
                throw "Orders API does not permit portal egress $ip/32. Review Network phase."
            }
        }
    }
    foreach ($app in $Inventory.apps) {
        $ready = $false
        for ($attempt = 0; $attempt -lt 12; $attempt++) {
            try {
                $response = Invoke-WebRequest -Uri "https://$($app.properties.defaultHostName)/health/ready" -TimeoutSec 30
                if ($response.StatusCode -eq 200 -and $response.Content.Trim() -eq 'Healthy') { $ready = $true; break }
                throw "Unexpected readiness response for $($app.name)."
            } catch {
                if ($attempt -eq 11) { throw "Readiness failed for $($app.name), possibly operator IP restrictions: $($_.Exception.Message)" }
                Start-Sleep -Seconds 10
            }
        }
        if (-not $ready) { throw "Not ready: $($app.name)" }
    }
}

function Get-SpikeState {
    $variables = Invoke-SpikeArm GET "$accountId/variables"
    $variablesFound = @($variables.value | Where-Object { $_.name -eq 'CostSpikeState' })
    if ($variablesFound.Count -eq 0) { return $null }
    $variablesFound[0].properties.value | ConvertFrom-Json | ConvertFrom-Json -AsHashtable
}

function Invoke-SpikeStateWrite {
    param([hashtable]$State)
    $json = $State | ConvertTo-Json -Depth 40 -Compress
    [void](Invoke-SpikeArm PUT "$accountId/variables/CostSpikeState" @{
        name = 'CostSpikeState'
        properties = @{ isEncrypted = $false; description = 'Owned cost-spike lifecycle and recovery evidence'; value = (ConvertTo-Json -InputObject $json -Compress) }
    })
}

function Wait-SpikeJob {
    param([string]$JobId)
    for ($poll = 0; $poll -lt 60; $poll++) {
        $job = Invoke-SpikeArm GET "$accountId/jobs/$JobId"
        if ($job.properties.status -eq 'Completed') { return }
        if ($job.properties.status -in @('Failed', 'Stopped', 'Suspended')) {
            throw "Automation verification job $JobId is $($job.properties.status). Inspect its error/output streams before starting."
        }
        Start-Sleep -Seconds 10
    }
    throw "Automation verification job $JobId did not complete in time. No scale-up is allowed."
}

function Assert-SpikeRecoveryAccess {
    param([hashtable]$State)
    $account = Invoke-SpikeArm GET $accountId
    $principal = $account.identity.principalId
    if ([string]::IsNullOrWhiteSpace($principal)) { throw 'Recovery account has no managed identity.' }
    $definitions = @($State.cleanupIds | Where-Object { $_ -like '*/roleDefinitions/*' })
    $assignments = @($State.cleanupIds | Where-Object { $_ -like '*/roleAssignments/*' })
    if ($definitions.Count -ne 1 -or $assignments.Count -ne 2) { throw 'Recovery permissions were not recorded correctly.' }
    $role = Invoke-SpikeArm GET $definitions[0] -Api '2022-04-01'
    $actions = @($role.properties.permissions[0].actions | Sort-Object)
    if (@($role.properties.permissions).Count -ne 1 -or
        @($role.properties.permissions[0].notActions).Count -ne 0 -or
        @($role.properties.permissions[0].dataActions).Count -ne 0 -or
        ($actions -join ',') -ne 'Microsoft.Web/serverfarms/read,Microsoft.Web/serverfarms/write') {
        throw 'Recovery custom role no longer has exactly plan read/write permissions.'
    }
    foreach ($assignmentId in $assignments) {
        $assignedPlan = ($assignmentId -split '/providers/Microsoft.Authorization/roleAssignments/')[0]
        if ($assignedPlan -notin $State.plans.id) { throw 'Recovery assignment is not scoped to an approved plan.' }
        $assignment = Invoke-SpikeArm GET $assignmentId -Api '2022-04-01'
        if ($assignment.properties.principalId -ne $principal -or $assignment.properties.roleDefinitionId -ne $definitions[0]) {
            throw 'Recovery role assignment no longer targets the correct identity/role.'
        }
    }
}

function Invoke-SpikeVerificationJob {
    param([hashtable]$State)
    Assert-SpikeRecoveryAccess $State
    $jobId = [guid]::NewGuid().ToString()
    [void](Invoke-SpikeArm PUT "$accountId/jobs/$jobId" @{
        properties = @{ runbook = @{ name = 'Restore-CostSpike' }; parameters = @{
            StateJson = ($State | ConvertTo-Json -Depth 40 -Compress); Mode = 'Verify'
        } }
    })
    Wait-SpikeJob $jobId
    $jobId
}

function Invoke-SpikeScheduleCreation {
    param([hashtable]$State, [string]$Name, [DateTimeOffset]$StartTime, [switch]$Recurring)
    $properties = @{ startTime = $StartTime.ToString('o'); timeZone = 'UTC'; frequency = 'OneTime'; description = $State.runId }
    if ($Recurring) { $properties.frequency = 'Hour'; $properties.interval = 1 }
    [void](Invoke-SpikeArm PUT "$accountId/schedules/$Name" @{ name = $Name; properties = $properties })
    $jobScheduleId = [guid]::NewGuid().ToString()
    $parameters = @{ StateJson = ($State | ConvertTo-Json -Depth 40 -Compress); Mode = 'Restore' }
    [void](Invoke-SpikeArm PUT "$accountId/jobSchedules/$jobScheduleId" @{
        properties = @{ schedule = @{ name = $Name }; runbook = @{ name = 'Restore-CostSpike' }; parameters = $parameters }
    })
    $observed = Invoke-SpikeArm GET "$accountId/schedules/$Name"
    $binding = Invoke-SpikeArm GET "$accountId/jobSchedules/$jobScheduleId"
    if (-not $observed.properties.isEnabled -or
        [math]::Abs(([DateTimeOffset]$observed.properties.startTime - $StartTime).TotalMinutes) -gt 1 -or
        $observed.properties.frequency -ne $properties.frequency -or
        $binding.properties.schedule.name -ne $Name -or $binding.properties.runbook.name -ne 'Restore-CostSpike' -or
        $binding.properties.parameters.StateJson -ne $parameters.StateJson -or $binding.properties.parameters.Mode -ne 'Restore') {
        throw 'Rollback schedule/binding could not be verified. No scale-up is allowed.'
    }
    @{ name = $Name; bindingId = $jobScheduleId }
}

function Invoke-SpikeScaleUp {
    param([hashtable]$Plan, [string]$RunId)
    $current = Get-SpikePlan $Plan.id
    Assert-SpikeBaseline @($current)
    $tags = @{} + $current.tags
    $tags.CostSpikeRun = $RunId
    [void](Invoke-SpikeArm PATCH $Plan.id @{ sku = @{ name = 'S3'; tier = 'Standard'; capacity = 1 }; tags = $tags } -Api '2025-03-01')
    for ($poll = 0; $poll -lt 60; $poll++) {
        $observed = Get-SpikePlan $Plan.id
        if ($observed.sku.name -eq 'S3' -and $observed.sku.capacity -eq 1 -and
            $observed.tags['CostSpikeRun'] -eq $RunId -and $observed.properties.provisioningState -eq 'Succeeded') { return }
        Start-Sleep -Seconds 10
    }
    throw "Scale-up was not verified: $($Plan.id)"
}

function Invoke-SpikeBudgetCreation {
    param([hashtable]$State, [string[]]$Emails)
    $month = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-01')
    [void](Invoke-SpikeArm PUT "/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/budgets/contoso-cost-spike" @{
        properties = @{
            category = 'Cost'; amount = $State.budget.amountNetGbp; timeGrain = 'Monthly'
            timePeriod = @{ startDate = $month; endDate = [DateTimeOffset]::Parse($month).AddMonths(2).ToString('yyyy-MM-dd') }
            filter = @{ dimensions = @{ name = 'ResourceId'; operator = 'In'; values = @($State.plans.id) } }
            notifications = @{ DemoActual = @{
                enabled = $true; operator = 'GreaterThanOrEqualTo'; threshold = 100; thresholdType = 'Actual'; contactEmails = $Emails
            } }
        }
    } -Api '2024-08-01')
    $observed = Invoke-SpikeArm GET "/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/budgets/contoso-cost-spike" -Api '2024-08-01'
    if ($observed.properties.amount -ne $State.budget.amountNetGbp -or
        (@($observed.properties.filter.dimensions.values | Sort-Object) -join ',') -ne
        (@($State.plans.id | Sort-Object) -join ',') -or
        -not $observed.properties.notifications.DemoActual.enabled) { throw 'Demo budget verification failed.' }
}

function Assert-SpikeCleanup {
    param([hashtable]$State)
    $rolePattern = "^/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/[0-9a-f-]{36}$"
    $alertId = "/subscriptions/$SubscriptionId/resourceGroups/rg-finops-development/providers/Microsoft.Insights/metricAlerts/contoso-cost-spike-job-failed"
    $assignments = @()
    $roles = @()
    foreach ($id in $State.cleanupIds) {
        if ($id -eq $accountId -or $id -eq $alertId) { continue }
        if ($id -match $rolePattern) { $roles += $id; continue }
        $planId = ($id -split '/providers/Microsoft.Authorization/roleAssignments/')[0]
        if ($planId -in $State.plans.id -and $id -match '/roleAssignments/[0-9a-f-]{36}$') { $assignments += $id; continue }
        throw "Invalid exact guardrail cleanup scope: $id"
    }
    if (@($State.cleanupIds).Count -ne 5 -or $assignments.Count -ne 2 -or $roles.Count -ne 1 -or
        @($State.cleanupIds | Sort-Object -Unique).Count -ne 5 -or
        $accountId -notin $State.cleanupIds -or $alertId -notin $State.cleanupIds) {
        throw 'Cleanup requires the exact account, failure alert, custom role and two plan-scoped assignments.'
    }
    $role = Invoke-SpikeArm GET $roles[0] -Api '2022-04-01'
    if ($role.properties.roleName -ne "Contoso cost spike plan recovery $SubscriptionId" -or
        $role.properties.type -ne 'CustomRole') { throw 'Cleanup custom role ownership does not match this demo.' }
    $account = Invoke-SpikeArm GET $accountId
    foreach ($id in $assignments) {
        $assignment = Invoke-SpikeArm GET $id -Api '2022-04-01'
        if ($assignment.properties.roleDefinitionId -ne $roles[0] -or
            $assignment.properties.principalId -ne $account.identity.principalId) {
            throw 'Cleanup role assignment ownership does not match this demo.'
        }
    }
    if ($State.ownsBudget) {
        $budget = Invoke-SpikeArm GET "/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/budgets/contoso-cost-spike" -Api '2024-08-01'
        if ((@($budget.properties.filter.dimensions.values | Sort-Object) -join ',') -ne
            (@($State.plans.id | Sort-Object) -join ',') -or $budget.properties.amount -ne $State.budget.amountNetGbp) {
            throw 'Demo budget was changed externally; review before cleanup.'
        }
    }
    if ($State.ownsAnomaly) {
        $anomaly = Invoke-SpikeArm GET "/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/scheduledActions/contoso-cost-spike-anomaly" -Api '2025-03-01'
        if ($anomaly.properties.displayName -ne 'Contoso cost spike native anomaly') {
            throw 'Demo anomaly rule was changed externally; review before cleanup.'
        }
    }
}
