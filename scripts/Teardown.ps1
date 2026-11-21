#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][switch]$AcknowledgeRecoveryLoss)
. "$PSScriptRoot\Common.ps1"
Assert-Subscription $SubscriptionId
if (-not $AcknowledgeRecoveryLoss) { throw 'Deleting SQL logical servers removes normal PITR; export required evidence first.' }
$groups = @('rg-finops-production','rg-finops-development','rg-finops-shared')
foreach ($group in $groups) {
    Assert-ProjectGroup $SubscriptionId $group
    $resources = Invoke-AzJson @('resource','list','--subscription',$SubscriptionId,'-g',$group)
    foreach ($resource in $resources) {
        if ($resource.type -match 'roleAssignments|diagnosticSettings|/config$|firewallRules|administrators|auditingSettings|extendedAuditingSettings|backup.*Policies|blobServices|managementPolicies|basicPublishingCredentialsPolicies' -or
            $resource.name -match '/master$') { continue }
        if ($resource.tags.Project -ne 'ContosoFinOpsDemo') { throw "Unrelated/untagged resource blocks deletion: $($resource.id)" }
    }
}
foreach ($group in $groups) {
    if ($PSCmdlet.ShouldProcess("$SubscriptionId/$group", 'DELETE all group resources including databases, exports and monitoring')) {
        Write-Output (Invoke-Az @('group','delete','--subscription',$SubscriptionId,'--name',$group,'--yes'))
        $exists = Invoke-Az @('group','exists','--subscription',$SubscriptionId,'--name',$group)
        if ($exists.Trim() -ne 'false') { throw "Deletion not verified for $group." }
    }
}
Write-Output 'Subscription-scoped project budgets and deployment history are retained; review/delete those exact records separately if required.'
