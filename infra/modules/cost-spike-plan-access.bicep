param planName string
param principalId string
param roleDefinitionId string
param accountName string

resource plan 'Microsoft.Web/serverfarms@2025-03-01' existing = { name: planName }
resource access 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(plan.id, roleDefinitionId, accountName)
  scope: plan
  properties: { principalId: principalId, principalType: 'ServicePrincipal', roleDefinitionId: roleDefinitionId }
}
output assignmentId string = access.id
