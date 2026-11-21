param name string
param location string = resourceGroup().location
param tags object
@allowed(['B1', 'B2'])
param sku string = 'B1'
param actionGroupId string

module plan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'plan'
  params: {
    name: name
    location: location
    tags: tags
    skuName: sku
    skuCapacity: 1
    kind: 'linux'
    reserved: true
    zoneRedundant: false
    perSiteScaling: false
    enableTelemetry: false
  }
}
resource cpuAlert 'Microsoft.Insights/metricAlerts@2026-01-01' = {
  name: '${name}-cpu'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    severity: 2
    scopes: [plan.outputs.resourceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [{
        name: 'Cpu'
        metricName: 'CpuPercentage'
        metricNamespace: 'Microsoft.Web/serverfarms'
        operator: 'GreaterThan'
        threshold: 80
        timeAggregation: 'Average'
        criterionType: 'StaticThresholdCriterion'
      }]
    }
    actions: [{ actionGroupId: actionGroupId }]
  }
}
output resourceId string = plan.outputs.resourceId
