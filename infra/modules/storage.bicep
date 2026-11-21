param name string
param location string = resourceGroup().location
param tags object

resource account 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: name
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_ZRS' }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
  }
}
resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: account
  name: 'default'
  properties: { deleteRetentionPolicy: { enabled: true, days: 7 } }
}
resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = [for name in ['report-exports', 'cost-exports']: {
  parent: blobs
  name: name
  properties: { publicAccess: 'None' }
}]
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2025-01-01' = {
  parent: account
  name: 'default'
  properties: {
    policy: {
      rules: [{
        name: 'ExpireReportExports'
        enabled: true
        type: 'Lifecycle'
        definition: {
          filters: { blobTypes: ['blockBlob'], prefixMatch: ['report-exports/orders/'] }
          actions: { baseBlob: { delete: { daysAfterModificationGreaterThan: 30 } } }
        }
      }]
    }
  }
}
output name string = account.name
output blobEndpoint string = account.properties.primaryEndpoints.blob
