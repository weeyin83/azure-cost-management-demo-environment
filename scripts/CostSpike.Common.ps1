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
        $Body | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $file
        Invoke-AzJson ($arguments + @('--body', "@$file"))
    } finally { Remove-Item -LiteralPath $file }
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
    if ($estimate.additional24HoursGross + $estimate.automationReserveGross -gt 20) {
        throw '24-hour additional compute plus GBP 2 Automation reserve exceeds the approved GBP 20 allowance.'
    }
    $estimate
}

function Get-SpikeBudgetPreview {
    param([object[]]$Plans, [hashtable]$Estimate)
    $now = [DateTimeOffset]::UtcNow
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
