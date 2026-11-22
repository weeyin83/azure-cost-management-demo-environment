targetScope = 'subscription'
param location string
param accountName string = 'contoso-cost-spike'
param developmentPlanName string
param productionPlanName string
param tags object
param actionGroupId string

resource role 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, 'ContosoCostSpikePlanRecovery')
  properties: {
    roleName: 'Contoso cost spike plan recovery ${subscription().subscriptionId}'
    description: 'Assigned only on the two cost-demo plans; no application, SQL, or network permissions.'
    type: 'CustomRole'
    permissions: [{
      actions: ['Microsoft.Web/serverfarms/read', 'Microsoft.Web/serverfarms/write']
      notActions: []
      dataActions: []
      notDataActions: []
    }]
    assignableScopes: [subscription().id]
  }
}
module account 'cost-spike-account.bicep' = {
  name: 'cost-spike-account'
  scope: resourceGroup('rg-finops-development')
  params: { name: accountName, location: location, tags: tags, actionGroupId: actionGroupId }
}
module developmentAccess 'cost-spike-plan-access.bicep' = {
  name: 'cost-spike-development-access'
  scope: resourceGroup('rg-finops-development')
  params: { planName: developmentPlanName, principalId: account.outputs.principalId, roleDefinitionId: role.id, accountName: accountName }
}
module productionAccess 'cost-spike-plan-access.bicep' = {
  name: 'cost-spike-production-access'
  scope: resourceGroup('rg-finops-shared')
  params: { planName: productionPlanName, principalId: account.outputs.principalId, roleDefinitionId: role.id, accountName: accountName }
}
output accountId string = account.outputs.accountId
output cleanupIds array = [
  developmentAccess.outputs.assignmentId
  productionAccess.outputs.assignmentId
  account.outputs.failureAlertId
  role.id
  account.outputs.accountId
]
