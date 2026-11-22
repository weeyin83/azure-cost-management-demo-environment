#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
$deploy = Join-Path (Split-Path $PSScriptRoot) 'scripts\Deploy.ps1'
$subscription = '11111111-1111-1111-1111-111111111111'
$calls = [System.Collections.Generic.List[object]]::new()
$fixture = @{}

# Shadow the native CLI so these tests cannot read or modify Azure.
function az {
    $arguments = @($args)
    $calls.Add($arguments)
    $global:LASTEXITCODE = 0
    $command = ($arguments | Select-Object -First 3) -join ' '
    if ($command -like 'account show *') {
        @{ id = $subscription; environmentName = 'AzureCloud' } | ConvertTo-Json -Compress
    } elseif ($command -eq 'rest --method get') {
        if ($arguments[[Array]::IndexOf($arguments, '--subscription') + 1] -ne $subscription -or
            $arguments[[Array]::IndexOf($arguments, '--query') + 1] -ne 'value') {
            throw 'REST lookups must target the explicit subscription and return the value array.'
        }
        $url = $arguments[[Array]::IndexOf($arguments, '--url') + 1]
        if ($url -eq "https://management.azure.com/subscriptions/$subscription/locations?api-version=2022-12-01") {
            ConvertTo-Json -InputObject @(@{ name = 'westeurope' }) -Compress
        } elseif ($url -eq "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.Storage/skus?api-version=2023-05-01") {
            $restrictions = @(if ($fixture['RestrictedStorage']) {
                @{ type = 'Location'; values = @('westeurope'); reasonCode = 'NotAvailableForSubscription' }
            })
            $items = @(if (-not $fixture['NoStorage']) {
                @{ name = 'Standard_ZRS'; kind = 'StorageV2'; locations = @('westeurope'); restrictions = $restrictions }
            })
            ConvertTo-Json -InputObject $items -Depth 10 -Compress
        } else {
            throw "Unexpected mock REST URL: $url"
        }
    } elseif ($command -like 'appservice list-locations *') {
        $sku = $arguments[[Array]::IndexOf($arguments, '--sku') + 1]
        $items = @(if ($sku -ne $fixture['UnavailableSku']) { @{ name = 'West Europe' } })
        ConvertTo-Json -InputObject $items -Compress
    } elseif ($command -eq 'webapp list-runtimes --os') {
        $config = if ($fixture['NoDotnet10']) { 'DOTNETCORE:8.0' } else { 'DOTNETCORE:10.0' }
        $items = @(if ($fixture['LegacyRuntimes']) { $config } else {
            @{ config = $config; runtime = '.NET'; os = 'Linux' }
        })
        ConvertTo-Json -InputObject $items -Compress
    } elseif ($command -eq 'sql db list-editions') {
        $items = @(if (-not $fixture['NoSql']) { @{ name = 'Basic' } })
        ConvertTo-Json -InputObject $items -Compress
    } elseif ($command -like 'group list *') {
        $items = @(if ($fixture['ExistingRegion']) {
            @{ name = 'rg-finops-production'; location = $fixture['ExistingRegion'] }
        })
        ConvertTo-Json -InputObject $items -Compress
    } elseif ($command -like 'group show *') {
        @{ tags = @{ Project = 'ContosoFinOpsDemo' } } | ConvertTo-Json -Compress
    } elseif ($command -like 'resource list *') {
        '[]'
    } elseif ($command -in @('deployment sub validate', 'deployment sub what-if', 'deployment sub create')) {
        $parameterPath = $arguments[[Array]::IndexOf($arguments, '--parameters') + 1]
        if (-not (Test-Path -LiteralPath $parameterPath) -or
            (-not $IsWindows -and $parameterPath.Contains('\'))) {
            throw "Invalid native CLI parameter path: $parameterPath"
        }
        '{}'
    } else {
        throw "Unexpected mock CLI command: $command"
    }
}

function Invoke-Case {
    param([string]$Region = 'westeurope', [string]$Profile = 'demo', [string]$Phase = 'Inspect')
    $calls.Clear()
    $env:CONTOSO_LOCATION = $Region
    & $deploy -SubscriptionId $subscription -BillingCurrency GBP -Profile $Profile -Phase $Phase `
        -CostEstimateReviewed -ApproveB2 -Confirm:$false | Out-Null
}

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Expected)
    $message = $null
    try { & $Action } catch { $message = $_.Exception.Message }
    if (-not $message -or $message -notlike "*$Expected*") {
        throw "Expected rejection containing '$Expected'; received '$message'."
    }
    if ($calls | Where-Object { ($_ | Select-Object -First 3) -join ' ' -eq 'deployment sub create' }) {
        throw 'A rejected case attempted creation.'
    }
}

$inputs = @{
    CONTOSO_LOCATION = 'westeurope'
    CONTOSO_PREFIX = 'testlab'
    CONTOSO_SQL_ADMIN_OBJECT_ID = $subscription
    CONTOSO_SQL_ADMIN_NAME = 'TestAdmin'
    CONTOSO_TENANT_ID = $subscription
    CONTOSO_BUDGET_EMAILS = 'demo@example.invalid'
}
$previous = @{}
foreach ($name in $inputs.Keys) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name, $inputs[$name])
}
try {
    Invoke-Case
    if (@($calls | Where-Object { ($_ | Select-Object -First 3) -join ' ' -eq 'rest --method get' }).Count -ne 2) {
        throw 'Expected subscription-scoped REST location and storage SKU lookups.'
    }
    $regionalCalls = @($calls | Where-Object {
        ($_ | Select-Object -First 3) -join ' ' -in @('sql db list-editions', 'deployment sub validate', 'deployment sub what-if')
    })
    if ($regionalCalls.Count -ne 3) { throw 'Expected SQL, validate and what-if regional commands.' }
    foreach ($arguments in $regionalCalls) {
        if ($arguments[[Array]::IndexOf($arguments, '--location') + 1] -ne 'westeurope') {
            throw 'Selected region was not propagated.'
        }
    }
    Invoke-Case -Profile development-baseline -Phase Create
    if (@($calls | Where-Object { ($_ | Select-Object -First 2) -join ' ' -eq 'appservice list-locations' }).Count -ne 2) {
        throw 'Both B1 and B2 must be checked for the baseline profile.'
    }
    $create = @($calls | Where-Object { ($_ | Select-Object -First 3) -join ' ' -eq 'deployment sub create' })
    if ($create.Count -ne 1 -or $create[0][[Array]::IndexOf($create[0], '--location') + 1] -ne 'westeurope') {
        throw 'Creation did not use the selected region.'
    }
    Assert-Rejected { Invoke-Case -Region '' } 'Supply CONTOSO_LOCATION'
    if ($calls.Count -ne 0) { throw 'Missing region should fail before even a mocked Azure call.' }
    Assert-Rejected { Invoke-Case -Region 'West Europe' } 'Supply CONTOSO_LOCATION'
    Assert-Rejected { Invoke-Case -Region 'unknownregion' } 'was not found'
    $fixture.UnavailableSku = 'B2'
    Assert-Rejected { Invoke-Case -Profile development-baseline } 'Linux B2 availability'
    $fixture.Clear()
    $fixture.LegacyRuntimes = $true
    Invoke-Case
    $fixture.NoDotnet10 = $true
    Assert-Rejected { Invoke-Case } 'App Service .NET 10 Linux runtime'
    $fixture.Clear()
    $fixture.NoDotnet10 = $true
    Assert-Rejected { Invoke-Case } 'App Service .NET 10 Linux runtime'
    $fixture.Clear()
    $fixture.NoSql = $true
    Assert-Rejected { Invoke-Case } 'Basic SQL availability'
    $fixture.Clear()
    $fixture.NoStorage = $true
    Assert-Rejected { Invoke-Case } 'Standard_ZRS availability'
    $fixture.Clear()
    $fixture.RestrictedStorage = $true
    Assert-Rejected { Invoke-Case } 'subscription restriction'
    $fixture.Clear()
    $fixture.ExistingRegion = 'uksouth'
    Assert-Rejected { Invoke-Case } 'Review migration or cleanup'
    Write-Output 'Deployment-region tests passed: propagation, B1/B2 checks and invalid/unsupported/restricted/migration guards. All Azure commands were mocked.'
} finally {
    foreach ($name in $inputs.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
}
