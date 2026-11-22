#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = & az @Arguments --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $($Arguments -join ' ')" }
    return ($result -join "`n")
}
function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    return ,(Invoke-Az ($Arguments + @('--output', 'json')) | ConvertFrom-Json -AsHashtable -NoEnumerate)
}
function Assert-Subscription {
    param([string]$Id)
    if (-not [guid]::TryParse($Id, [ref]([guid]::Empty))) { throw 'Supply an explicit subscription GUID.' }
    $account = Invoke-AzJson @('account', 'show', '--subscription', $Id)
    if ($account.id -ne $Id -or $account.environmentName -ne 'AzureCloud') {
        throw 'The explicit Azure public-cloud subscription could not be verified.'
    }
}
function Assert-ProjectGroup {
    param([string]$Subscription, [string]$Group)
    if ($Group -notin @('rg-finops-production', 'rg-finops-development', 'rg-finops-shared')) {
        throw "Group is outside the three-group estate: $Group"
    }
    $groupObject = Invoke-AzJson @('group', 'show', '--subscription', $Subscription, '--name', $Group)
    if ($groupObject.tags.Project -ne 'ContosoFinOpsDemo') { throw "Project tag mismatch: $Group" }
}
function Get-Estate {
    param([string]$Subscription, [string]$DeploymentName = 'contoso-finops')
    $deployment = Invoke-AzJson @('deployment', 'sub', 'show', '--subscription', $Subscription, '--name', $DeploymentName)
    if ($deployment.properties.provisioningState -ne 'Succeeded') { throw 'The core deployment has not succeeded.' }
    $result = @{}
    foreach ($key in $deployment.properties.outputs.Keys) { $result[$key] = $deployment.properties.outputs[$key].value }
    foreach ($group in @('rg-finops-production', 'rg-finops-development', 'rg-finops-shared')) {
        Assert-ProjectGroup $Subscription $group
    }
    foreach ($environment in @('Production', 'Development')) {
        $group = "rg-finops-$($environment.ToLowerInvariant())"
        $inventory = Invoke-AzJson @('webapp', 'list', '--subscription', $Subscription, '-g', $group)
        $apps = @($inventory | Where-Object { $_.tags.Project -eq 'ContosoFinOpsDemo' })
        $roles = @(if ($environment -eq 'Production') { 'OrdersAPI', 'CustomerPortal', 'ReportingPortal' } else { 'DevelopmentPortal' })
        if ($apps.Count -ne $roles.Count) { throw "Expected $($roles.Count) project apps in $group; found $($apps.Count)." }
        $resolved = @(
            foreach ($role in $roles) {
                $matches = @($apps | Where-Object { $_.tags.Application -eq $role -and $_.tags.Environment -eq $environment })
                if ($matches.Count -ne 1) { throw "Expected exactly one tagged $role app in $group; found $($matches.Count)." }
                $app = $matches[0]
                $principalId = if ($null -ne $app.identity) { $app.identity.principalId } else { '' }
                if ([string]::IsNullOrWhiteSpace($app.defaultHostName) -or
                    ($role -ne 'CustomerPortal' -and [string]::IsNullOrWhiteSpace($principalId))) {
                    throw "Missing hostname or required managed identity for $($app.name)."
                }
                @{ role = $role; name = $app.name; resourceId = $app.id; principalId = $principalId;
                    endpoint = "https://$($app.defaultHostName)/" }
            }
        )
        $key = if ($environment -eq 'Production') { 'productionApplications' } else { 'developmentApplication' }
        foreach ($app in $resolved) {
            $previous = @($result[$key] | Where-Object { $environment -eq 'Development' -or $_.role -eq $app.role })
            if ($previous.Count -ne 1 -or $previous[0].name -ne $app.name) {
                Write-Warning "Deployment output for $($app.role) is stale; using verified live app $($app.name)."
            }
        }
        $result[$key] = if ($environment -eq 'Production') { $resolved } else { $resolved[0] }
    }
    return $result
}
function Assert-Address {
    param([string]$Address, [switch]$Cidr, [switch]$AllowDisabled)
    if ($AllowDisabled -and $Address -eq '255.255.255.255') { return }
    $parts = $Address.Split('/')
    $parsed = [System.Net.IPAddress]::None
    if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref]$parsed) -or
        $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $parsed.ToString() -ne $parts[0] -or
        $parts[0] -in @('0.0.0.0', '255.255.255.255')) { throw "Invalid IPv4 address: $Address" }
    if ($Cidr) {
        $prefix = 0
        if ($parts.Count -ne 2 -or -not [int]::TryParse($parts[1], [ref]$prefix) -or $prefix -lt 24 -or $prefix -gt 32) {
            throw 'Use explicitly approved IPv4 CIDRs /24 through /32, preferably /32.'
        }
    } elseif ($parts.Count -ne 1) { throw 'An individual IPv4 address is required.' }
}
