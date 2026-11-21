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
