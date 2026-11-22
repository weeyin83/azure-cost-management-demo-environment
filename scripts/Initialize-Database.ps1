#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateSet('Production','Development')][string]$Environment,
    [switch]$Seed,
    [string]$Dotnet = 'dotnet'
)
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Subscription $SubscriptionId
$estate = Get-Estate $SubscriptionId
$server = if ($Environment -eq 'Production') { $estate.sqlServers.production } else { $estate.sqlServers.development }
$group = "rg-finops-$($Environment.ToLowerInvariant())"
$administrators = Invoke-AzJson @('sql','server','ad-admin','list','--subscription',$SubscriptionId,'-g',$group,'--server',$server)
$tenantId = [guid]::Empty
if ($administrators.Count -ne 1 -or
    -not [guid]::TryParse($administrators[0].tenantId, [ref]$tenantId) -or $tenantId -eq [guid]::Empty) {
    throw 'The selected SQL server must have exactly one Entra administrator with a valid tenant ID.'
}
$cliAccount = Invoke-AzJson @('account','show')
if ($cliAccount.tenantId -ne $tenantId.ToString()) {
    throw "The current Azure CLI login is not in the SQL administrator tenant. Run az login --tenant $tenantId using the configured SQL administrator or a member of its group, then retry. No account or permissions are changed automatically."
}
Write-Host "SQL administrator: $($administrators[0].login). Initialization uses only the Azure CLI login in tenant $tenantId; Azure RBAC alone does not grant SQL access."
$app = if ($Environment -eq 'Production') { $estate.productionApplications | Where-Object { $_.role -eq 'OrdersAPI' } } else { $estate.developmentApplication }
if ([string]::IsNullOrWhiteSpace($app.principalId)) { throw 'The SQL application has no managed identity.' }
$principal = Invoke-AzJson @('ad','sp','show','--id',$app.principalId)
if ($principal.id -ne $app.principalId -or $principal.displayName -ne $app.name -or
    $principal.servicePrincipalType -ne 'ManagedIdentity' -or
    [string]::IsNullOrWhiteSpace($principal.appId)) {
    throw 'Managed identity object/client ID and display name could not be verified. No directory permissions are granted automatically.'
}
if ($PSCmdlet.ShouldProcess("$server/orders", 'Apply reviewed schema, least-privilege identity grants and optional seed as Entra administrator')) {
    $root = Split-Path $PSScriptRoot
    $seedValue = if ($Seed) { 'true' } else { 'false' }
    $initializationOutput = @()
    & $Dotnet run --project (Join-Path $root 'src/ContosoFinOps/DotNetCoreSqlDb.csproj') --no-launch-profile -- `
        --initialize-database=true "--server=$server.database.windows.net" "--runtime-user=$($app.name)" `
        "--runtime-client-id=$($principal.appId)" "--tenant-id=$tenantId" `
        "--sql-script-directory=$(Join-Path $PSScriptRoot 'sql')" "--seed=$seedValue" `
        2>&1 | Tee-Object -Variable initializationOutput
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $details = if ($initializationOutput.Count -gt 0) { $initializationOutput -join "`n" } else {
            'The initializer emitted no diagnostic output. Check that the selected .NET executable can run under local application-control policy.'
        }
        throw "Database initialization failed (exit code $exitCode); no runtime/schema success is claimed.`n$details"
    }
}
