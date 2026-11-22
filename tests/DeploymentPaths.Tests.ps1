#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$subscription = '11111111-1111-1111-1111-111111111111'
$calls = [System.Collections.Generic.List[object]]::new()
$dotnetCalls = [System.Collections.Generic.List[object]]::new()
$archiveCalls = [System.Collections.Generic.List[object]]::new()
$apps = @(
    @{ name = 'test-orders'; role = 'OrdersAPI'; principalId = $subscription },
    @{ name = 'test-customer'; role = 'CustomerPortal' },
    @{ name = 'test-reports'; role = 'ReportingPortal' }
)
$development = @{ name = 'test-development'; principalId = $subscription }
$staleOutputs = $false
$missingCustomer = $false
$runtimeName = 'test-orders'
$runtimeServer = 'test-prod'
$failInitialization = $false
$emptyInitializationFailure = $false

function Assert-NativePath {
    param([string]$Path, [switch]$Existing)
    if (-not [IO.Path]::IsPathRooted($Path) -or (-not $IsWindows -and $Path.Contains('\'))) {
        throw "Invalid native CLI path: $Path"
    }
    if ($Existing -and -not (Test-Path -LiteralPath $Path)) { throw "Missing path: $Path" }
}

# Shadow all external commands so no Azure access, build or publication occurs.
function az {
    $arguments = @($args)
    $calls.Add($arguments)
    $global:LASTEXITCODE = 0
    $command = ($arguments | Select-Object -First 3) -join ' '
    switch -Wildcard ($command) {
        'account show *' {
            @{ id = $subscription; environmentName = 'AzureCloud' } | ConvertTo-Json -Compress
        }
        'deployment sub show' {
            $outputs = @{}
            $productionOutputs = if ($staleOutputs) {
                @($apps[0], @{ name = 'test-reports'; role = 'CustomerPortal'; principalId = $subscription }, $apps[2])
            } else { $apps }
            foreach ($pair in @{
                productionApplications = $productionOutputs
                developmentApplication = $development
                sqlServers = @{ production = 'test-prod'; development = 'test-dev' }
                developmentPlanName = 'test-plan'
            }.GetEnumerator()) { $outputs[$pair.Key] = @{ value = $pair.Value } }
            @{ properties = @{ provisioningState = 'Succeeded'; outputs = $outputs } } |
                ConvertTo-Json -Depth 10 -Compress
        }
        'group show *' { @{ tags = @{ Project = 'ContosoFinOpsDemo' } } | ConvertTo-Json -Compress }
        'webapp list *' {
            $group = $arguments[[Array]::IndexOf($arguments, '-g') + 1]
            $environment = if ($group -eq 'rg-finops-production') { 'Production' } else { 'Development' }
            $items = if ($environment -eq 'Production') { $apps } else {
                @(@{ name = $development.name; role = 'DevelopmentPortal'; principalId = $subscription })
            }
            $live = @(
                foreach ($item in $items) {
                    if ($missingCustomer -and $item.role -eq 'CustomerPortal') { continue }
                    @{ name = $item.name
                        id = "/subscriptions/$subscription/resourceGroups/$group/providers/Microsoft.Web/sites/$($item.name)"
                        defaultHostName = "$($item.name).azurewebsites.net"
                        identity = if ($item.role -eq 'CustomerPortal') { $null } else { @{ principalId = $subscription } }
                        tags = @{ Project = 'ContosoFinOpsDemo'; Application = $item.role; Environment = $environment } }
                }
            )
            ConvertTo-Json -InputObject $live -Depth 10 -Compress
        }
        'webapp show *' { @{ possibleOutboundIpAddresses = '203.0.113.10' } | ConvertTo-Json -Compress }
        'webapp config show' { '{}' }
        'sql server firewall-rule' { '[]' }
        'resource show *' { @{ tags = @{ Project = 'ContosoFinOpsDemo' } } | ConvertTo-Json -Compress }
        'monitor action-group list' { '[{"id":"test-action","tags":{"Project":"ContosoFinOpsDemo"}}]' }
        'deployment group *' {
            Assert-NativePath $arguments[[Array]::IndexOf($arguments, '--template-file') + 1] -Existing
            $parameters = $arguments[[Array]::IndexOf($arguments, '--parameters') + 1]
            Assert-NativePath $parameters.Substring(1) -Existing
            $payload = Get-Content -LiteralPath $parameters.Substring(1) -Raw | ConvertFrom-Json -AsHashtable
            if ($payload.parameters.ContainsKey('sites')) {
                $sites = @($payload.parameters.sites.value)
                if (@($sites.name | Sort-Object -Unique).Count -ne $sites.Count) {
                    throw 'Network template contains duplicate sites.'
                }
                $group = $arguments[[Array]::IndexOf($arguments, '-g') + 1]
                if ($group -eq 'rg-finops-production' -and
                    (($sites.name | Sort-Object) -join ',') -ne 'test-customer,test-orders,test-reports') {
                    throw 'Network template does not target the three actual production apps.'
                }
            }
            '{}'
        }
        'webapp deploy *' {
            Assert-NativePath $arguments[[Array]::IndexOf($arguments, '--src-path') + 1]
            '{}'
        }
        'ad sp show' {
            if ('--subscription' -in $arguments -or
                $arguments[[Array]::IndexOf($arguments, '--id') + 1] -ne $subscription) {
                throw 'Directory lookups must use the verified managed identity ID without --subscription.'
            }
            @{ id = $subscription; displayName = $runtimeName; servicePrincipalType = 'ManagedIdentity'; appId = $subscription } |
                ConvertTo-Json -Compress
        }
        default { throw "Unexpected mocked Azure command: $command" }
    }
}

function Mock-Dotnet {
    $arguments = @($args)
    $dotnetCalls.Add($arguments)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'publish') {
        Assert-NativePath $arguments[1] -Existing
        Assert-NativePath $arguments[[Array]::IndexOf($arguments, '-o') + 1]
    } elseif ($arguments[0] -eq 'run') {
        Assert-NativePath $arguments[[Array]::IndexOf($arguments, '--project') + 1] -Existing
        if ("--runtime-user=$runtimeName" -notin $arguments -or
            "--server=$runtimeServer.database.windows.net" -notin $arguments -or
            "--runtime-client-id=$subscription" -notin $arguments) {
            throw 'Database initialization must use the verified identity and selected environment server.'
        }
        $directory = @($arguments | Where-Object { $_ -like '--sql-script-directory=*' })
        if ($directory.Count -ne 1) { throw 'Missing SQL script directory.' }
        Assert-NativePath ($directory[0] -replace '^--sql-script-directory=', '') -Existing
        if ($failInitialization) {
            Write-Output 'Applying reviewed migrations as the explicitly authenticated administrator.'
            & pwsh -NoProfile -Command '[Console]::Error.WriteLine("SqlException: Login failed for the administrator."); exit 42'
            $global:LASTEXITCODE = 42
        } elseif ($emptyInitializationFailure) {
            $global:LASTEXITCODE = 43
        }
    } else { throw 'Unexpected mocked dotnet command.' }
}

function Compress-Archive {
    param([string]$Path, [string]$DestinationPath, [switch]$Force)
    Assert-NativePath $Path
    Assert-NativePath $DestinationPath
    $archiveCalls.Add(@($Path, $DestinationPath))
}

$deploy = Join-Path $root 'scripts/Deploy.ps1'
foreach ($phase in @('Network', 'ResizeDevelopment', 'Publish')) {
    & $deploy -SubscriptionId $subscription -BillingCurrency GBP -Phase $phase `
        -ApprovedAddresses @('203.0.113.20/32') -BootstrapAdministratorAddress '203.0.113.20' `
        -DatabaseInitializationConfirmed -Dotnet Mock-Dotnet -Confirm:$false | Out-Null
}
foreach ($environment in @('Production', 'Development')) {
    $runtimeName = if ($environment -eq 'Production') { 'test-orders' } else { 'test-development' }
    $runtimeServer = if ($environment -eq 'Production') { 'test-prod' } else { 'test-dev' }
    & (Join-Path $root 'scripts/Initialize-Database.ps1') -SubscriptionId $subscription `
        -Environment $environment -Dotnet Mock-Dotnet -Confirm:$false | Out-Null
}
if (@($calls | Where-Object { ($_ | Select-Object -First 3) -join ' ' -eq 'deployment group create' }).Count -ne 3) {
    throw 'Expected network deployments for both groups and a development resize.'
}
if (@($calls | Where-Object { ($_ | Select-Object -First 2) -join ' ' -eq 'webapp deploy' }).Count -ne 4 -or
    $dotnetCalls.Count -ne 3 -or $archiveCalls.Count -ne 1) {
    throw 'Expected publication to four apps and initialization of both databases.'
}
$failInitialization = $true
$message = $null
try {
    & (Join-Path $root 'scripts/Initialize-Database.ps1') -SubscriptionId $subscription `
        -Environment Development -Dotnet Mock-Dotnet -Confirm:$false | Out-Null
} catch { $message = $_.Exception.Message }
if ($message -notlike '*exit code 42*' -or
    $message -notlike '*Applying reviewed migrations*' -or
    $message -notlike '*SqlException: Login failed for the administrator.*' -or
    $message -notlike '*no runtime/schema success is claimed*') {
    throw "Initialization failure must retain the native exit code, stdout and stderr: $message"
}
$failInitialization = $false
$emptyInitializationFailure = $true
$message = $null
try {
    & (Join-Path $root 'scripts/Initialize-Database.ps1') -SubscriptionId $subscription `
        -Environment Development -Dotnet Mock-Dotnet -Confirm:$false | Out-Null
} catch { $message = $_.Exception.Message }
if ($message -notlike '*exit code 43*' -or $message -notlike '*emitted no diagnostic output*') {
    throw "Initialization failure without output must still report its exit code: $message"
}
$emptyInitializationFailure = $false
$staleOutputs = $true
$calls.Clear()
foreach ($phase in @('Network', 'Publish')) {
    & $deploy -SubscriptionId $subscription -BillingCurrency GBP -Phase $phase `
        -ApprovedAddresses @('203.0.113.20/32') -DatabaseInitializationConfirmed `
        -Dotnet Mock-Dotnet -Confirm:$false | Out-Null
}
$published = @($calls | Where-Object { ($_ | Select-Object -First 2) -join ' ' -eq 'webapp deploy' } |
    ForEach-Object { $_[[Array]::IndexOf($_, '-n') + 1] } | Sort-Object)
if (($published -join ',') -ne 'test-customer,test-development,test-orders,test-reports') {
    throw 'Stale deployment outputs must still publish exactly once to each actual app.'
}
$missingCustomer = $true
$calls.Clear()
$message = $null
try {
    & $deploy -SubscriptionId $subscription -BillingCurrency GBP -Phase Network `
        -ApprovedAddresses @('203.0.113.20/32') -Confirm:$false | Out-Null
} catch { $message = $_.Exception.Message }
if ($message -notlike '*Expected 3 project apps*' -or
    @($calls | Where-Object { ($_ | Select-Object -First 3) -join ' ' -eq 'deployment group create' }).Count -ne 0) {
    throw 'Incomplete live inventory must fail before any network deployment.'
}
Write-Output 'Deployment-path tests passed: Network, ResizeDevelopment, Publish and database initialization. All external commands were mocked.'
