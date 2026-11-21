param namePrefix string
param location string = resourceGroup().location
param tags object
param notificationEmails array

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: '${namePrefix}-logs'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: json('0.1') }
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${namePrefix}-email'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    groupShortName: 'ContosoDemo'
    emailReceivers: [for (email, i) in notificationEmails: {
      name: 'Contact-${i}'
      emailAddress: email
      useCommonAlertSchema: true
    }]
  }
}
output workspaceId string = workspace.id
output actionGroupId string = actionGroup.id
