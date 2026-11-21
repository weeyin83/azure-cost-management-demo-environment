#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([Parameter(Mandatory)][string]$SubscriptionId, [switch]$WriteChecks)
. "$PSScriptRoot\Common.ps1"
Assert-Subscription $SubscriptionId
$estate = Get-Estate $SubscriptionId
$resources = @()
foreach ($group in @('rg-finops-production','rg-finops-development','rg-finops-shared')) {
    $resources += Invoke-AzJson @('resource','list','--subscription',$SubscriptionId,'-g',$group)
}
foreach ($resource in $resources) {
    if ($resource.type -match 'roleAssignments|budgets|diagnosticSettings|/config$|firewallRules|administrators|auditingSettings|extendedAuditingSettings|backup.*Policies|blobServices|managementPolicies|basicPublishingCredentialsPolicies' -or
        $resource.name -match '/master$') { continue }
    foreach ($tag in @('Environment','Application','Owner','CostCentre','Project','ManagedBy')) {
        if ($null -eq $resource.tags -or -not $resource.tags.ContainsKey($tag) -or [string]::IsNullOrWhiteSpace($resource.tags[$tag])) {
            throw "Missing $tag on $($resource.id)"
        }
    }
}
foreach ($pair in @(@('Microsoft.Web/sites',4),@('Microsoft.Web/serverfarms',2),@('Microsoft.Sql/servers',2),
    @('Microsoft.Sql/servers/databases',2),@('Microsoft.Insights/components',4),@('Microsoft.OperationalInsights/workspaces',1),
    @('Microsoft.Storage/storageAccounts',1))) {
    $actual = @($resources | Where-Object { $_.type -eq $pair[0] -and $_.name -notmatch '/master$' }).Count
    if ($actual -ne $pair[1]) { throw "Expected $($pair[1]) $($pair[0]); found $actual." }
}
foreach ($plan in $resources | Where-Object { $_.type -eq 'Microsoft.Web/serverfarms' }) {
    $details = Invoke-AzJson @('resource','show','--subscription',$SubscriptionId,'--ids',$plan.id)
    if ($details.sku.name -notin @('B1','B2') -or $details.sku.capacity -ne 1 -or
        -not $details.properties.reserved -or $details.properties.zoneRedundant) {
        throw "Unexpected plan SKU/worker/Linux/zone settings: $($plan.id)"
    }
    if ($plan.id -match '/rg-finops-shared/' -and $details.sku.name -ne 'B1') {
        throw 'Production shared plan is not the approved B1.'
    }
}
foreach ($pair in @(@('rg-finops-production',$estate.sqlServers.production,7,'Geo'),
    @('rg-finops-development',$estate.sqlServers.development,1,'Local'))) {
    $db = Invoke-AzJson @('sql','db','show','--subscription',$SubscriptionId,'-g',$pair[0],'-s',$pair[1],'-n','orders')
    if ($db.sku.tier -ne 'Basic' -or $db.sku.capacity -ne 5 -or
        $db.maxSizeBytes -ne 2147483648 -or $db.zoneRedundant -or $db.requestedBackupStorageRedundancy -ne $pair[3]) {
        throw "Unexpected SQL tier/capacity/backup settings: $($pair[1])"
    }
    $retention = Invoke-AzJson @('sql','db','str-policy','show','--subscription',$SubscriptionId,'-g',$pair[0],'-s',$pair[1],'-n','orders')
    if ($retention.retentionDays -ne $pair[2]) { throw "Unexpected PITR retention: $($pair[1])" }
    $authentication = Invoke-AzJson @('sql','server','ad-only-auth','get','--subscription',$SubscriptionId,'-g',$pair[0],'-n',$pair[1])
    if (-not $authentication.azureADOnlyAuthentication) { throw "SQL is not Entra-only: $($pair[1])" }
    $rules = Invoke-AzJson @('sql','server','firewall-rule','list','--subscription',$SubscriptionId,'-g',$pair[0],'-s',$pair[1])
    foreach ($rule in $rules) {
        if ($rule.name -eq 'administrator-bootstrap') {
            if ($rule.startIpAddress -ne '255.255.255.255' -or $rule.endIpAddress -ne '255.255.255.255') {
                throw 'Temporary SQL administrator access is still enabled.'
            }
        } else {
            Assert-Address $rule.startIpAddress
            if ($rule.startIpAddress -ne $rule.endIpAddress -or $rule.name -notmatch '^app-egress-\d+$') {
                throw 'Unexpected/broad SQL firewall rule.'
            }
        }
    }
}
foreach ($app in @($estate.productionApplications) + @($estate.developmentApplication)) {
    $group = if ($app.name -eq $estate.developmentApplication.name) { 'rg-finops-development' } else { 'rg-finops-production' }
    $config = Invoke-AzJson @('webapp','config','show','--subscription',$SubscriptionId,'-g',$group,'-n',$app.name)
    $details = Invoke-AzJson @('webapp','show','--subscription',$SubscriptionId,'-g',$group,'-n',$app.name)
    if (-not $details.httpsOnly -or $config.linuxFxVersion -ne 'DOTNETCORE|10.0' -or
        $config.minTlsVersion -notin @('1.2','1.3') -or $config.ftpsState -ne 'Disabled' -or
        $config.healthCheckPath -ne '/health/ready') { throw "Unexpected app TLS/runtime/health settings: $($app.name)" }
    foreach ($policy in @('scm','ftp')) {
        $publishing = Invoke-AzJson @('resource','show','--subscription',$SubscriptionId,
            '--ids',"$($app.resourceId)/basicPublishingCredentialsPolicies/$policy",'--api-version','2025-03-01')
        if ($publishing.properties.allow) { throw "Basic $policy publishing credentials are enabled." }
    }
    $settings = Invoke-AzJson @('webapp','config','appsettings','list','--subscription',$SubscriptionId,'-g',$group,'-n',$app.name)
    $sqlSettings = @($settings | Where-Object { $_.name -eq 'ConnectionStrings__Orders' })
    $expectedRole = if ($group -eq 'rg-finops-development') { 'DevelopmentPortal' } else { $app.role }
    $roleSetting = @($settings | Where-Object { $_.name -eq 'Deployment__Role' })
    if ($roleSetting.Count -ne 1 -or $roleSetting[0].value -ne $expectedRole) { throw 'App deployment role mismatch.' }
    if ($expectedRole -in @('CustomerPortal','ReportingPortal') -and $sqlSettings.Count -ne 0) {
        throw 'Production portal unexpectedly has SQL configuration.'
    }
    if ($expectedRole -in @('OrdersAPI','DevelopmentPortal') -and
        ($sqlSettings.Count -ne 1 -or $sqlSettings[0].value -notmatch 'Authentication=Active Directory Managed Identity')) {
        throw 'SQL app lacks managed-identity SQL configuration.'
    }
    if ($config.ipSecurityRestrictionsDefaultAction -ne 'Deny' -or $config.scmIpSecurityRestrictionsDefaultAction -ne 'Deny') {
        throw "Ingress is not deny-default: $($app.name)"
    }
    foreach ($rule in $config.ipSecurityRestrictions) {
        if ($rule.action -eq 'Allow') { Assert-Address $rule.ipAddress -Cidr }
    }
    foreach ($rule in $config.scmIpSecurityRestrictions) {
        if ($rule.action -eq 'Allow') { Assert-Address $rule.ipAddress -Cidr }
    }
    $response = Invoke-WebRequest ($app.endpoint + 'health/ready')
    if ($response.StatusCode -ne 200) { throw "App is not ready: $($app.name)" }
}
if ($WriteChecks -and $PSCmdlet.ShouldProcess($SubscriptionId, 'Create, complete and delete one clearly identified test request per database')) {
    $api = $estate.productionApplications | Where-Object { $_.role -eq 'OrdersAPI' }
    foreach ($endpoint in @($api.endpoint, $estate.developmentApplication.endpoint)) {
        $created = $null
        try {
            $created = Invoke-RestMethod ($endpoint + 'api/orders') -Method Post -ContentType 'application/json' `
                -Body (@{ description="Validation $([guid]::NewGuid())"; category='IT' } | ConvertTo-Json)
            Invoke-RestMethod ($endpoint + "api/orders/$($created.id)/status") -Method Put -ContentType 'application/json' `
                -Body '{"status":"Completed"}'
            $read = Invoke-RestMethod ($endpoint + "api/orders/$($created.id)")
            if ($read.status -ne 'Completed') { throw 'Status change was not persisted.' }
        } finally {
            if ($null -ne $created) { Invoke-RestMethod ($endpoint + "api/orders/$($created.id)") -Method Delete }
        }
    }
}
Write-Output 'Inventory, supported tags, deny-default ingress and readiness checks passed. SQL grants, isolation, backups and Turbo reconciliation still require their documented checks.'
