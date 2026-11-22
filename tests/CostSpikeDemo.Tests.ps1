#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$subscription = '11111111-1111-1111-1111-111111111111'
$scope = "/subscriptions/$subscription"
$accountId = "$scope/resourceGroups/rg-finops-development/providers/Microsoft.Automation/automationAccounts/contoso-cost-spike"
$demo = Join-Path $root 'scripts/Invoke-CostSpikeDemo.ps1'
$global:spikeTestCalls = [System.Collections.Generic.List[object]]::new()

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Fails {
    param([scriptblock]$Action, [string]$Message)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    if ($null -eq $caught -or $caught -notlike "*$Message*") { throw "Expected '$Message', received '$caught'." }
}
function Reset-Fixture {
    $global:spikeTestPlans = @{}
    foreach ($group in @('rg-finops-development', 'rg-finops-shared')) {
        $id = "$scope/resourceGroups/$group/providers/Microsoft.Web/serverfarms/$group-plan"
        $global:spikeTestPlans[$id] = @{
            id = $id; name = "$group-plan"; location = 'swedencentral'
            tags = @{ Project = 'ContosoFinOpsDemo'; Application = 'Plan'; Environment = 'Development'; Owner = 'Demo'; CostCentre = 'Demo'; ManagedBy = 'Bicep' }
            sku = @{ name = 'B1'; capacity = 1; tier = 'Basic' }
            properties = @{ reserved = $true; zoneRedundant = $false; perSiteScaling = $false; provisioningState = 'Succeeded' }
        }
    }
    $global:spikeTestApps = @()
    foreach ($role in @('DevelopmentPortal', 'OrdersAPI', 'CustomerPortal', 'ReportingPortal')) {
        $dev = $role -eq 'DevelopmentPortal'
        $group = if ($dev) { 'rg-finops-development' } else { 'rg-finops-production' }
        $planGroup = if ($dev) { 'rg-finops-development' } else { 'rg-finops-shared' }
        $global:spikeTestApps += @{
            id = "$scope/resourceGroups/$group/providers/Microsoft.Web/sites/$role"; name = $role
            defaultHostName = "$role.azurewebsites.net"; identity = @{ principalId = $subscription }
            tags = @{ Project = 'ContosoFinOpsDemo'; Application = $role; Environment = $(if ($dev) { 'Development' } else { 'Production' }) }
            properties = @{
                serverFarmId = "$scope/resourceGroups/$planGroup/providers/Microsoft.Web/serverfarms/$planGroup-plan"
                possibleOutboundIpAddresses = '203.0.113.10'; defaultHostName = "$role.azurewebsites.net"
            }
        }
    }
    $global:spikeTestPrepared = $false
    $global:spikeTestVariable = $null
    $global:spikeTestResources = @{}
    $global:spikeTestS3Price = [decimal]0.2857
    $global:spikeTestMissingCosts = $false
    $global:spikeTestStaleCosts = $false
    $global:spikeTestCurrency = 'GBP'
    $global:spikeTestMissingEgress = $false
    $global:spikeTestFailSchedule = $false
    $global:spikeTestFailScale = $false
    $global:spikeTestFailVerify = $false
    $global:spikeTestUnsupported = $false
    $global:spikeTestFailRestore = $false
    $global:spikeTestCalls.Clear()
}
function Start-Sleep { param([int]$Seconds) }
function Invoke-RestMethod {
    param([string]$Uri, [int]$TimeoutSec)
    if ($Uri -notlike 'https://prices.azure.com/*') { throw "Unexpected public HTTP: $Uri" }
    @{ Items = @(
        @{ productName = 'Azure App Service Basic Plan - Linux'; skuName = 'B1'; unitOfMeasure = '1 Hour'; currencyCode = 'GBP'; tierMinimumUnits = 0; retailPrice = [decimal]0.0135 },
        @{ productName = 'Azure App Service Standard Plan - Linux'; skuName = 'S3'; unitOfMeasure = '1 Hour'; currencyCode = 'GBP'; tierMinimumUnits = 0; retailPrice = $global:spikeTestS3Price }
    ); NextPageLink = $null }
}
function Invoke-WebRequest {
    param([string]$Uri, [int]$TimeoutSec)
    if ($Uri -notlike 'https://*.azurewebsites.net/health/ready') { throw "Unexpected app HTTP: $Uri" }
    @{ StatusCode = 200; Content = 'Healthy' }
}
function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    $global:spikeTestCalls.Add($arguments)
    $command = ($arguments | Select-Object -First 3) -join ' '
    $result = switch -Wildcard ($command) {
        'account show*' { @{ id = $subscription; environmentName = 'AzureCloud' }; break }
        'group show*' { @{ tags = @{ Project = 'ContosoFinOpsDemo' } }; break }
        'deployment sub show' {
            @{
                properties = @{
                    provisioningState = 'Succeeded'
                    outputs = @{
                        productionApplications = @{ value = @($global:spikeTestApps | Where-Object { $_.tags.Environment -eq 'Production' } | ForEach-Object { @{ name = $_.name; role = $_.tags.Application } }) }
                        developmentApplication = @{ value = @{ name = 'DevelopmentPortal' } }
                        sqlServers = @{ value = @{ development = 'dev-sql'; production = 'prod-sql' } }
                    }
                }
            }; break
        }
        'webapp list*' {
            $group = $arguments[[Array]::IndexOf($arguments, '-g') + 1]
            ,@($global:spikeTestApps | Where-Object { $_.id -like "*/resourceGroups/$group/*" }); break
        }
        'resource list*' {
            if ($global:spikeTestPrepared) {
                ,@(@{ id = $accountId; tags = @{ Project = 'ContosoFinOpsDemo'; Application = 'CostSpikeGuardrail' } })
            } else { ,@() }
            break
        }
        'sql server firewall-rule' {
            if ($global:spikeTestMissingEgress) { ,@() } else { ,@(@{ startIpAddress = '203.0.113.10'; endIpAddress = '203.0.113.10' }) }
            break
        }
        'webapp config access-restriction' { @{ ipSecurityRestrictions = @(@{ action = 'Allow'; ipAddress = '203.0.113.10/32' }) }; break }
        'appservice list-locations*' {
            if ($global:spikeTestUnsupported) { ,@() } else { ,@(@{ name = 'Sweden Central' }) }
            break
        }
        'consumption budget list' { ,@(); break }
        'monitor action-group list' { ,@(@{ id = "$scope/resourceGroups/rg-finops-shared/providers/Microsoft.Insights/actionGroups/email"; tags = @{ Project = 'ContosoFinOpsDemo' }; enabled = $true; emailReceivers = @(@{ name = 'test' }) }); break }
        'deployment sub create' {
            $global:spikeTestPrepared = $true
            $ids = @($global:spikeTestPlans.Keys | Sort-Object | ForEach-Object { "$_/providers/Microsoft.Authorization/roleAssignments/22222222-2222-2222-2222-222222222222" }) +
                @("$scope/resourceGroups/rg-finops-development/providers/Microsoft.Insights/metricAlerts/contoso-cost-spike-job-failed",
                    $accountId, "$scope/providers/Microsoft.Authorization/roleDefinitions/33333333-3333-3333-3333-333333333333")
            @{ properties = @{ provisioningState = 'Succeeded'; outputs = @{ cleanupIds = @{ value = $ids } } } }; break
        }
        'rest *' {
            $method = $arguments[[Array]::IndexOf($arguments, '--method') + 1].ToUpperInvariant()
            $url = $arguments[[Array]::IndexOf($arguments, '--url') + 1]
            if ($url -notlike "https://management.azure.com$scope/*") { throw "Unscoped ARM: $url" }
            $id = $url.Replace('https://management.azure.com', '').Split('?')[0]
            $body = $null
            if ('--body' -in $arguments) {
                $path = $arguments[[Array]::IndexOf($arguments, '--body') + 1].Substring(1)
                if ($id -notlike '*/draft/content') { $body = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable }
            }
            if ($method -eq 'DELETE') {
                if ($id -eq $accountId) { $global:spikeTestPrepared = $false }
                $global:spikeTestResources.Remove($id)
                @{}; break
            }
            if ($global:spikeTestPlans.ContainsKey($id)) {
                if ($method -eq 'PATCH') {
                    if ($body.sku.name -eq 'S3' -and $global:spikeTestFailScale -and $id -like '*/rg-finops-shared/*') { throw 'Simulated second-plan scale failure' }
                    if ($body.sku.name -eq 'B1' -and $global:spikeTestFailRestore -and $id -like '*/rg-finops-development/*') { throw 'Simulated first-plan restore failure' }
                    $global:spikeTestPlans[$id].sku = $body.sku
                    $global:spikeTestPlans[$id].tags = $body.tags
                }
                $global:spikeTestPlans[$id]; break
            }
            $app = @($global:spikeTestApps | Where-Object { $_.id -eq $id })
            if ($app.Count) { $app[0]; break }
            if ($id -like '*/Microsoft.CostManagement/query') {
                $date = [DateTimeOffset]::UtcNow.AddDays($(if ($global:spikeTestStaleCosts) { -8 } else { -1 })).ToString('yyyyMMdd')
                $rows = if ($global:spikeTestMissingCosts) { @() } else { ,@([decimal]0.50, [int]$date, $global:spikeTestCurrency) }
                @{ properties = @{ columns = @(@{ name = 'Cost' }, @{ name = 'UsageDate' }, @{ name = 'Currency' }); rows = $rows } }; break
            }
            if ($id -like '*/Microsoft.CostManagement/scheduledActions') { @{ value = @() }; break }
            if ($id -eq "$accountId/variables") {
                if ($global:spikeTestVariable) { @{ value = @(@{ name = 'CostSpikeState'; properties = @{ value = $global:spikeTestVariable.properties.value } }) } }
                else { @{ value = @() } }
                break
            }
            if ($id -eq "$accountId/variables/CostSpikeState") {
                $global:spikeTestVariable = $body
                $body; break
            }
            if ($id -like '*/draft/content' -or $id -like '*/publish') { @{}; break }
            if ($id -eq "$accountId/runbooks/Restore-CostSpike") { @{ properties = @{ state = 'Published' } }; break }
            if ($method -eq 'PUT') {
                if ($id -like '*/schedules/*') {
                    if ($global:spikeTestFailSchedule) { throw 'Simulated schedule creation failure' }
                    $body.properties.isEnabled = $true
                }
                $global:spikeTestResources[$id] = $body
                $body; break
            }
            if ($id -like "$accountId/jobs/*") {
                @{ properties = @{ status = $(if ($global:spikeTestFailVerify) { 'Failed' } else { 'Completed' }) } }; break
            }
            if ($global:spikeTestResources.ContainsKey($id)) { $global:spikeTestResources[$id]; break }
            throw "Unexpected mocked ARM: $method $id"
        }
        default { throw "Unexpected mocked CLI: $command" }
    }
    ConvertTo-Json -InputObject $result -Depth 60 -Compress
}
function Invoke-Demo {
    param([string]$Phase, [switch]$WhatIf)
    & $demo -SubscriptionId $subscription -BillingCurrency GBP -Phase $Phase `
        -NotificationEmails @('demo@example.invalid') -AcknowledgeIntentionalSpend `
        -ReviewedBudgetAmount $global:spikeTestReviewedBudget -Confirm:$false -WhatIf:$WhatIf
}
function Set-ReviewedBudget {
    $preview = @(Invoke-Demo Inspect | Where-Object { $_ -is [string] -and $_ -like '*amountNetGbp*' })
    $global:spikeTestReviewedBudget = ($preview[-1] | ConvertFrom-Json).amountNetGbp
}
function Get-PlanWrites {
    ,@($global:spikeTestCalls | Where-Object {
        $_[0] -eq 'rest' -and $_[[Array]::IndexOf($_, '--method') + 1] -eq 'PATCH' -and
        $_[[Array]::IndexOf($_, '--url') + 1] -like '*/serverfarms/*'
    })
}

Reset-Fixture
$global:spikeTestReviewedBudget = 0
. (Join-Path $root 'scripts/CostSpike.Common.ps1')
$SubscriptionId = $subscription
$estimate = Get-SpikeEstimate swedencentral
Assert-Test ($estimate.additional20HoursGross -eq [decimal]13.07 -and $estimate.additional24HoursGross -eq [decimal]15.68) 'Reference spend arithmetic failed.'
$global:spikeTestS3Price = [decimal]0.33
Assert-Fails { Get-SpikeEstimate swedencentral } 'exceeds'
Reset-Fixture
$global:spikeTestMissingCosts = $true
Assert-Fails { Invoke-Demo Inspect } 'Missing billed'
$global:spikeTestMissingCosts = $false; $global:spikeTestStaleCosts = $true
Assert-Fails { Invoke-Demo Inspect } 'stale'
$global:spikeTestStaleCosts = $false; $global:spikeTestCurrency = 'USD'
Assert-Fails { Invoke-Demo Inspect } 'GBP'
Reset-Fixture
@($global:spikeTestPlans.Values)[0].tags.Project = 'Other'
Assert-Fails { Invoke-Demo Prepare } 'ownership'
Reset-Fixture
$global:spikeTestMissingEgress = $true
Assert-Fails { Invoke-Demo Prepare } 'SQL does not permit'
Assert-Test ((Get-PlanWrites).Count -eq 0) 'Connectivity failure must not resize.'
Reset-Fixture
$global:spikeTestUnsupported = $true
Assert-Fails { Invoke-Demo Prepare } 'availability'
Reset-Fixture
Set-ReviewedBudget
Invoke-Demo Prepare -WhatIf | Out-Null
Assert-Test (-not $global:spikeTestPrepared) 'Prepare WhatIf wrote resources.'
Invoke-Demo Prepare | Out-Null
$global:spikeTestFailVerify = $true
Assert-Fails { Invoke-Demo Start } 'verification job'
Assert-Test ((Get-PlanWrites).Count -eq 0) 'Failed guardrail verification must not resize.'
$global:spikeTestFailVerify = $false
Invoke-Demo Start -WhatIf | Out-Null
Assert-Test ((Get-PlanWrites).Count -eq 0) 'Start WhatIf resized.'
Invoke-Demo Start | Out-Null
Assert-Test (@($global:spikeTestPlans.Values | Where-Object { $_.sku.name -eq 'S3' }).Count -eq 2) 'Both targets must be observed.'
$firstPatch = -1; $lastBinding = -1
for ($i = 0; $i -lt $global:spikeTestCalls.Count; $i++) {
    $entry = $global:spikeTestCalls[$i]
    if ($entry[0] -ne 'rest') { continue }
    $url = $entry[[Array]::IndexOf($entry, '--url') + 1]
    $method = $entry[[Array]::IndexOf($entry, '--method') + 1]
    if ($method -eq 'GET' -and $url -like '*/jobSchedules/*') { $lastBinding = $i }
    if ($method -eq 'PATCH' -and $firstPatch -lt 0) { $firstPatch = $i }
}
Assert-Test ($lastBinding -ge 0 -and $lastBinding -lt $firstPatch) 'Both rollback bindings must be verified before the first resize.'
Assert-Fails { Invoke-Demo Start } 'baseline'
Invoke-Demo Restore | Out-Null
$before = (Get-PlanWrites).Count
Invoke-Demo Restore | Out-Null
Assert-Test ((Get-PlanWrites).Count -eq $before) 'Repeated restoration must not write plans.'
Invoke-Demo Cleanup | Out-Null
Assert-Test (-not $global:spikeTestPrepared) 'Cleanup did not delete guardrails.'
Assert-Test (@($global:spikeTestPlans.Values | Where-Object { $_.sku.name -eq 'B1' }).Count -eq 2) 'Cleanup changed the baseline.'

Reset-Fixture
Set-ReviewedBudget
Invoke-Demo Prepare | Out-Null
$global:spikeTestFailSchedule = $true
Assert-Fails { Invoke-Demo Start } 'baseline was restored'
Assert-Test ((Get-PlanWrites).Count -eq 0) 'Schedule failure must block all scale-up writes.'
Reset-Fixture
Set-ReviewedBudget
Invoke-Demo Prepare | Out-Null
$global:spikeTestFailScale = $true
Assert-Fails { Invoke-Demo Start } 'baseline was restored'
Assert-Test (@($global:spikeTestPlans.Values | Where-Object { $_.sku.name -eq 'B1' -and -not $_.tags.CostSpikeRun }).Count -eq 2) 'Partial start must compensate both plans.'

Reset-Fixture
Set-ReviewedBudget
Invoke-Demo Prepare | Out-Null
Invoke-Demo Start | Out-Null
$global:spikeTestFailRestore = $true
Assert-Fails { Invoke-Demo Restore } 'other plans were still attempted'
Assert-Test (@($global:spikeTestPlans.Values | Where-Object { $_.id -like '*/rg-finops-shared/*' -and $_.sku.name -eq 'B1' }).Count -eq 1) 'Failure on development must not skip production recovery.'
$global:spikeTestFailRestore = $false
$dev = @($global:spikeTestPlans.Values | Where-Object { $_.id -like '*/rg-finops-development/*' })[0]
$dev.sku.name = 'S2'
Assert-Fails { Invoke-Demo Restore } 'Unexpected intervening'
Assert-Test ($dev.sku.name -eq 'S2') 'An intervening resize must not be overwritten.'
Write-Output 'Cost-spike tests passed. All Azure, pricing, application requests and sleeps were mocked.'
