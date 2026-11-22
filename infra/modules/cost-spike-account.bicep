param name string
param location string
param tags object
param actionGroupId string

resource account 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: name
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: { sku: { name: 'Basic' } }
}
resource runtime 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23' = {
  parent: account
  name: 'CostSpikePowerShell'
  location: location
  properties: { runtime: { language: 'PowerShell', version: '7.4' } }
}
resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  parent: account
  name: 'Restore-CostSpike'
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell'
    runtimeEnvironment: runtime.name
    logProgress: false
    logVerbose: false
    description: 'Restores only the two explicitly approved cost-demo App Service plans.'
  }
}
resource failureAlert 'Microsoft.Insights/metricAlerts@2026-01-01' = {
  name: '${name}-job-failed'
  location: 'global'
  tags: tags
  properties: {
    description: 'Cost demo job failed or suspended. Inspect jobs and restore both plans immediately.'
    enabled: true
    severity: 1
    scopes: [account.id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [{
        name: 'RecoveryFailure'
        criterionType: 'StaticThresholdCriterion'
        metricName: 'TotalJob'
        metricNamespace: 'Microsoft.Automation/automationAccounts'
        operator: 'GreaterThan'
        threshold: 0
        timeAggregation: 'Total'
        dimensions: [{ name: 'Status', operator: 'Include', values: ['Failed', 'Suspended', 'Stopped'] }]
      }]
    }
    actions: [{ actionGroupId: actionGroupId }]
  }
}
output principalId string = account.identity.principalId
output accountId string = account.id
output failureAlertId string = failureAlert.id
