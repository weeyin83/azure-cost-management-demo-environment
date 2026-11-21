#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateSet('Production','Development')][string]$Environment,
    [Parameter(Mandatory)][DateTimeOffset]$RestoreTime,
    [Parameter(Mandatory)][ValidatePattern('^orders-restore-[a-z0-9-]+$')][string]$Destination,
    [ValidateSet('Basic','S3')][string]$Tier = 'Basic'
)
. "$PSScriptRoot\Common.ps1"
Assert-Subscription $SubscriptionId
$estate = Get-Estate $SubscriptionId
$group = if ($Environment -eq 'Production') { 'rg-finops-production' } else { 'rg-finops-development' }
$server = if ($Environment -eq 'Production') { $estate.sqlServers.production } else { $estate.sqlServers.development }
$source = Invoke-AzJson @('sql','db','show','--subscription',$SubscriptionId,'-g',$group,'-s',$server,'-n','orders')
if ($source.tags.Project -ne 'ContosoFinOpsDemo') { throw 'Source database project tag does not match.' }
if ($RestoreTime.UtcDateTime -ge [DateTime]::UtcNow -or
    $RestoreTime.UtcDateTime -lt [DateTimeOffset]::Parse($source.earliestRestoreDate).UtcDateTime) {
    throw 'Restore time is outside the currently available PITR range.'
}
$existing = Invoke-AzJson @('sql','db','list','--subscription',$SubscriptionId,'-g',$group,'-s',$server)
if ($existing | Where-Object { $_.name -eq $Destination }) { throw 'Destination already exists; never overwrite it.' }
if ($PSCmdlet.ShouldProcess("$server/$Destination", "Create a separately billable $Tier PITR database; no promised restore duration")) {
    $edition = if ($Tier -eq 'Basic') { 'Basic' } else { 'Standard' }
    $result = Invoke-AzJson @('sql','db','restore','--subscription',$SubscriptionId,'-g',$group,'-s',$server,'-n','orders',
        '--dest-name',$Destination,'--time',$RestoreTime.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'),
        '--edition',$edition,'--service-objective',$Tier)
    $tagArguments = @()
    foreach ($key in $source.tags.Keys) { $tagArguments += "$key=$($source.tags[$key])" }
    [void](Invoke-Az (@('resource','tag','--subscription',$SubscriptionId,'--ids',$result.id,'--tags') + $tagArguments))
    Write-Output "Restore requested: $($result.id). Validate content explicitly and delete only this temporary database afterward."
}
