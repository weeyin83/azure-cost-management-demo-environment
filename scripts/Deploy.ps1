#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateSet('GBP')][string]$BillingCurrency,
    [ValidateSet('Inspect', 'Create', 'Network', 'Publish', 'ResizeDevelopment')][string]$Phase = 'Inspect',
    [ValidateSet('demo', 'development-baseline')][string]$Profile = 'demo',
    [switch]$CostEstimateReviewed,
    [switch]$ApproveB2,
    [switch]$DatabaseInitializationConfirmed,
    [string[]]$ApprovedAddresses = @(),
    [string]$BootstrapAdministratorAddress = '255.255.255.255',
    [string]$Dotnet = 'dotnet'
)
. "$PSScriptRoot\Common.ps1"
if ($Phase -in @('Inspect', 'Create')) {
    $location = $env:CONTOSO_LOCATION
    if ($location -cnotmatch '^[a-z][a-z0-9]+$') {
        throw 'Supply CONTOSO_LOCATION as an explicit lowercase Azure region code, for example westeurope. No region is selected automatically.'
    }
}
Assert-Subscription $SubscriptionId
$root = Split-Path $PSScriptRoot
$parameters = Join-Path $root "infra\parameters\$Profile.bicepparam"

if ($Phase -in @('Inspect', 'Create')) {
    if ($env:CONTOSO_PREFIX -notmatch '^[a-z][a-z0-9]{2,11}$') { throw 'CONTOSO_PREFIX must be 3-12 lowercase alphanumeric characters starting with a letter.' }
    foreach ($name in @('CONTOSO_SQL_ADMIN_OBJECT_ID', 'CONTOSO_SQL_ADMIN_NAME', 'CONTOSO_TENANT_ID', 'CONTOSO_BUDGET_EMAILS')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Supply $name securely." }
    }
    foreach ($email in $env:CONTOSO_BUDGET_EMAILS.Split(',')) { [void][System.Net.Mail.MailAddress]::new($email) }
    $regions = Invoke-AzJson @('account', 'list-locations', '--subscription', $SubscriptionId)
    if (-not ($regions | Where-Object { $_.name -eq $location })) {
        throw "The selected region '$location' was not found for this subscription."
    }
    $skus = @('B1')
    if ($Profile -eq 'development-baseline') { $skus += 'B2' }
    foreach ($sku in $skus) {
        $locations = Invoke-AzJson @('appservice', 'list-locations', '--subscription', $SubscriptionId,
            '--sku', $sku, '--linux-workers-enabled')
        if (-not ($locations | Where-Object { ($_.name -replace '\s', '').ToLowerInvariant() -eq $location })) {
            throw "Linux $sku availability in '$location' was not confirmed."
        }
    }
    $runtimes = Invoke-AzJson @('webapp', 'list-runtimes', '--os', 'linux')
    if ('DOTNETCORE:10.0' -notin $runtimes) { throw 'App Service .NET 10 Linux runtime was not confirmed.' }
    $editions = Invoke-AzJson @('sql', 'db', 'list-editions', '--subscription', $SubscriptionId, '--location', $location)
    if (-not ($editions | Where-Object { $_.name -eq 'Basic' })) { throw "Basic SQL availability in '$location' was not confirmed." }
    $storageSkus = Invoke-AzJson @('storage', 'account', 'list-skus', '--subscription', $SubscriptionId)
    $zrsSkus = @($storageSkus | Where-Object {
        $_.name -eq 'Standard_ZRS' -and $_.kind -eq 'StorageV2' -and $location -in $_.locations
    })
    if ($zrsSkus.Count -eq 0) { throw "StorageV2 Standard_ZRS availability in '$location' was not confirmed." }
    foreach ($sku in $zrsSkus) {
        foreach ($restriction in $sku.restrictions) {
            if ($restriction.type -ne 'Location' -or -not $restriction.values -or $location -in $restriction.values) {
                throw "Standard_ZRS has a subscription restriction requiring review for '$location'."
            }
        }
    }
    $groups = Invoke-AzJson @('group', 'list', '--subscription', $SubscriptionId)
    foreach ($group in $groups | Where-Object { $_.name -in @('rg-finops-production','rg-finops-development','rg-finops-shared') }) {
        Assert-ProjectGroup $SubscriptionId $group.name
        if ($group.location -ne $location) {
            throw "Existing group '$($group.name)' is in '$($group.location)', not '$location'. Review migration or cleanup before changing the estate's region."
        }
        $resources = Invoke-AzJson @('resource', 'list', '--subscription', $SubscriptionId, '--resource-group', $group.name)
        if ($resources | Where-Object { $_.name -notlike "$($env:CONTOSO_PREFIX)*" -and $_.type -notmatch 'roleAssignments' }) {
            throw 'Existing resources do not match the selected prefix. Review before redeployment.'
        }
    }
    [void](Invoke-Az @('deployment','sub','validate','--subscription',$SubscriptionId,'--location',$location,
        '--parameters',$parameters))
    Write-Output (Invoke-Az @('deployment','sub','what-if','--subscription',$SubscriptionId,'--location',$location,
        '--parameters',$parameters))
    if ($Phase -eq 'Create') {
        if (-not $CostEstimateReviewed -or ($Profile -eq 'development-baseline' -and -not $ApproveB2)) {
            throw 'Review current GBP/VAT costs explicitly; B2 requires its own approval.'
        }
        if ($PSCmdlet.ShouldProcess($SubscriptionId, "Create/modify billable Azure resources in '$location' with CLOSED app ingress")) {
            Write-Output (Invoke-Az @('deployment','sub','create','--subscription',$SubscriptionId,'--location',$location,
                '--name','contoso-finops','--parameters',$parameters))
        }
    }
    return
}
$estate = Get-Estate $SubscriptionId
if ($Phase -eq 'Network') {
    if ($ApprovedAddresses.Count -eq 0) { throw 'Supply approved filming/development IPv4 CIDRs.' }
    foreach ($address in $ApprovedAddresses) { Assert-Address $address -Cidr }
    Assert-Address $BootstrapAdministratorAddress -AllowDisabled
    $appObjects = @{}
    foreach ($app in @($estate.productionApplications) + @($estate.developmentApplication)) {
        $group = if ($app.name -eq $estate.developmentApplication.name) { 'rg-finops-development' } else { 'rg-finops-production' }
        $appObjects[$app.name] = Invoke-AzJson @('webapp','show','--subscription',$SubscriptionId,'-g',$group,'-n',$app.name)
    }
    $portalIps = @()
    foreach ($app in $estate.productionApplications | Where-Object { $_.role -ne 'OrdersAPI' }) {
        $portalIps += $appObjects[$app.name].possibleOutboundIpAddresses.Split(',', [StringSplitOptions]::RemoveEmptyEntries)
    }
    foreach ($group in @('rg-finops-production','rg-finops-development')) {
        $isDev = $group -eq 'rg-finops-development'
        $apps = if ($isDev) { @($estate.developmentApplication) } else { @($estate.productionApplications) }
        $sqlApp = if ($isDev) { $estate.developmentApplication } else { $apps | Where-Object { $_.role -eq 'OrdersAPI' } }
        $sqlIps = @($appObjects[$sqlApp.name].possibleOutboundIpAddresses.Split(',', [StringSplitOptions]::RemoveEmptyEntries) | Sort-Object -Unique)
        if ($sqlIps.Count -eq 0) { throw 'No possible outbound addresses returned; do not open a broad firewall.' }
        if ($sqlIps.Count -gt 255) { throw 'The SQL address set exceeds firewall-rule capacity. Review architecture rather than widening access.' }
        foreach ($ip in $sqlIps + $portalIps) { Assert-Address $ip }
        $server = if ($isDev) { $estate.sqlServers.development } else { $estate.sqlServers.production }
        $existingRules = Invoke-AzJson @('sql','server','firewall-rule','list','--subscription',$SubscriptionId,'-g',$group,'-s',$server)
        $expected = @('administrator-bootstrap') + @(0..($sqlIps.Count-1) | ForEach-Object { "app-egress-$_" })
        if ($existingRules | Where-Object { $_.name -notin $expected }) {
            throw 'Unexpected/obsolete SQL firewall rules exist. Review and explicitly remove them before applying the current Bicep configuration.'
        }
        $sites = @()
        foreach ($app in $apps) {
            $config = Invoke-AzJson @('webapp','config','show','--subscription',$SubscriptionId,'-g',$group,'-n',$app.name)
            foreach ($key in @('id','name','type','location','tags','kind','appSettings','connectionStrings','publishingUsername')) { [void]$config.Remove($key) }
            $allowed = @($ApprovedAddresses)
            if (-not $isDev -and $app.role -eq 'OrdersAPI') {
                $allowed += @($portalIps | Sort-Object -Unique | ForEach-Object { "$_/32" })
            }
            $sites += @{ name=$app.name; config=$config; allowedAddresses=$allowed; administratorAddresses=$ApprovedAddresses }
        }
        $file = Join-Path ([IO.Path]::GetTempPath()) "contoso-network-$([guid]::NewGuid()).json"
        try {
            @{ parameters=@{ sites=@{value=$sites}; sqlServerName=@{value=$server}; sqlOutboundAddresses=@{value=$sqlIps};
                bootstrapAdministratorAddress=@{value=$BootstrapAdministratorAddress} } } | ConvertTo-Json -Depth 100 | Set-Content $file
            $arguments = @('deployment','group','what-if','--subscription',$SubscriptionId,'-g',$group,
                '--template-file',"$root\infra\modules\network-access.bicep",'--parameters',"@$file")
            Write-Output (Invoke-Az $arguments)
            if ($PSCmdlet.ShouldProcess($group, 'Apply approved ingress/egress rules (including bootstrap access state)')) {
                $arguments[2] = 'create'
                Write-Output (Invoke-Az $arguments)
            }
        } finally { Remove-Item -LiteralPath $file }
    }
    return
}
if ($Phase -eq 'ResizeDevelopment') {
    if ($Profile -eq 'development-baseline' -and -not $ApproveB2) { throw 'B2 is opt-in and billable.' }
    $planId = "/subscriptions/$SubscriptionId/resourceGroups/rg-finops-development/providers/Microsoft.Web/serverfarms/$($estate.developmentPlanName)"
    $plan = Invoke-AzJson @('resource','show','--ids',$planId,'--subscription',$SubscriptionId)
    $groups = Invoke-AzJson @('monitor','action-group','list','--subscription',$SubscriptionId,'-g','rg-finops-shared')
    $actionGroup = @($groups | Where-Object { $_.tags.Project -eq 'ContosoFinOpsDemo' })
    if ($actionGroup.Count -ne 1) { throw 'Exactly one tagged email action group is required.' }
    $sku = if ($Profile -eq 'demo') { 'B1' } else { 'B2' }
    $file = Join-Path ([IO.Path]::GetTempPath()) "contoso-resize-$([guid]::NewGuid()).json"
    try {
        @{parameters=@{name=@{value=$estate.developmentPlanName}; tags=@{value=$plan.tags}; sku=@{value=$sku};
            actionGroupId=@{value=$actionGroup[0].id}}} | ConvertTo-Json -Depth 20 | Set-Content $file
        $arguments=@('deployment','group','what-if','--subscription',$SubscriptionId,'-g','rg-finops-development',
            '--template-file',"$root\infra\modules\app-service-plan.bicep",'--parameters',"@$file")
        Write-Output (Invoke-Az $arguments)
        if ($PSCmdlet.ShouldProcess($planId, "Resize development ONLY to $sku")) {
            $arguments[2]='create'
            Write-Output (Invoke-Az $arguments)
        }
    } finally { Remove-Item -LiteralPath $file }
    return
}
if (-not $DatabaseInitializationConfirmed) { throw 'Initialize both databases and close temporary admin access before publishing.' }
if ($PSCmdlet.ShouldProcess($SubscriptionId, 'Publish the reviewed local package to all four applications')) {
    $publish = Join-Path $root '.artifacts\publish'
    & $Dotnet publish "$root\src\ContosoFinOps\DotNetCoreSqlDb.csproj" -c Release -r linux-x64 `
        --self-contained false -p:UseAppHost=false -o $publish
    if ($LASTEXITCODE -ne 0) { throw 'Application publication build failed.' }
    $zip = Join-Path $root '.artifacts\contoso.zip'
    Compress-Archive -Path "$publish\*" -DestinationPath $zip -Force
    $ordered = @($estate.productionApplications | Where-Object { $_.role -eq 'OrdersAPI' }) +
        @($estate.developmentApplication) + @($estate.productionApplications | Where-Object { $_.role -ne 'OrdersAPI' })
    foreach ($app in $ordered) {
        $group = if ($app.name -eq $estate.developmentApplication.name) { 'rg-finops-development' } else { 'rg-finops-production' }
        Write-Output (Invoke-Az @('webapp','deploy','--subscription',$SubscriptionId,'-g',$group,'-n',$app.name,
            '--src-path',$zip,'--type','zip','--clean','true','--restart','true'))
    }
}
