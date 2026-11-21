param storageName string
param principalId string
resource account 'Microsoft.Storage/storageAccounts@2025-01-01' existing = { name: storageName }
resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' existing = { parent: account, name: 'default' }
resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' existing = {
  parent: blobs
  name: 'report-exports'
}
resource reportRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(container.id, principalId, 'report-export')
  scope: container
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}
