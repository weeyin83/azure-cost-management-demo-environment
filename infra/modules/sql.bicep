param name string
param location string = resourceGroup().location
param tags object
param administratorObjectId string
param administratorLogin string
@allowed(['User', 'Group', 'Application'])
param administratorType string
param tenantId string
@allowed([1, 7])
param retentionDays int
@allowed(['Geo', 'Local'])
param backupRedundancy string

module server 'br/public:avm/res/sql/server:0.23.0' = {
  name: 'sql-server'
  params: {
    name: name
    location: location
    tags: tags
    enableTelemetry: false
    publicNetworkAccess: 'Enabled'
    minimalTlsVersion: '1.2'
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      login: administratorLogin
      principalType: administratorType
      sid: administratorObjectId
      tenantId: tenantId
    }
    auditSettings: { state: 'Disabled' }
    firewallRules: []
    databases: [{
      name: 'orders'
      availabilityZone: -1
      sku: { name: 'Basic', tier: 'Basic', capacity: 5 }
      maxSizeBytes: 2147483648
      zoneRedundant: false
      requestedBackupStorageRedundancy: backupRedundancy
      backupShortTermRetentionPolicy: { retentionDays: retentionDays }
      tags: tags
    }]
  }
}
output name string = server.outputs.name
output databaseName string = 'orders'
