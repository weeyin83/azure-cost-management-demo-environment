param name string
param location string = resourceGroup().location
param tags object
@allowed(['CustomerPortal', 'OrdersAPI', 'ReportingPortal', 'DevelopmentPortal'])
param role string
param planId string
param workspaceId string
param actionGroupId string
param sqlServerName string = ''
param databaseName string = 'orders'
param apiBaseUri string = ''
param reportStorageUri string = ''

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${name}-insights'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspaceId
    IngestionMode: 'LogAnalytics'
    DisableIpMasking: false
    SamplingPercentage: 20
  }
}
var usesSql = contains(['OrdersAPI', 'DevelopmentPortal'], role)
var settings = concat([
  { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
  { name: 'ASPNETCORE_FORWARDEDHEADERS_ENABLED', value: 'true' }
  { name: 'Deployment__Role', value: role }
  { name: 'Deployment__EnvironmentLabel', value: tags.Environment }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
  { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'false' }
], usesSql ? [{
  name: 'ConnectionStrings__Orders'
  value: 'Server=tcp:${sqlServerName}${environment().suffixes.sqlServerHostname},1433;Database=${databaseName};Authentication=Active Directory Managed Identity;Encrypt=true;TrustServerCertificate=false;Connection Timeout=15;'
}] : [{ name: 'Deployment__ApiBaseUri', value: apiBaseUri }],
role == 'ReportingPortal' ? [{ name: 'Deployment__ReportStorageUri', value: reportStorageUri }] : [])
module app 'br/public:avm/res/web/site:0.24.0' = {
  name: '${name}-web-app'
  params: {
    name: name
    location: location
    tags: tags
    kind: 'app,linux'
    serverFarmResourceId: planId
    managedIdentities: { systemAssigned: role != 'CustomerPortal' }
    httpsOnly: true
    clientAffinityEnabled: false
    publicNetworkAccess: 'Enabled'
    enableTelemetry: false
    basicPublishingCredentialsPolicies: [{ name: 'scm', allow: false }, { name: 'ftp', allow: false }]
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|10.0'
      alwaysOn: true
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      healthCheckPath: '/health/ready'
      appSettings: settings
      ipSecurityRestrictionsDefaultAction: 'Deny'
      scmIpSecurityRestrictionsDefaultAction: 'Deny'
      scmIpSecurityRestrictionsUseMain: false
      ipSecurityRestrictions: []
      scmIpSecurityRestrictions: []
    }
  }
}
resource errorsAlert 'Microsoft.Insights/metricAlerts@2026-01-01' = if (role == 'OrdersAPI') {
  name: '${name}-http-errors'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    severity: 2
    scopes: [app.outputs.resourceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [{
        name: 'HttpErrors'
        metricName: 'Http5xx'
        metricNamespace: 'Microsoft.Web/sites'
        operator: 'GreaterThan'
        threshold: 5
        timeAggregation: 'Total'
        criterionType: 'StaticThresholdCriterion'
      }]
    }
    actions: [{ actionGroupId: actionGroupId }]
  }
}
output name string = app.outputs.name
output resourceId string = app.outputs.resourceId
output principalId string = app.outputs.?systemAssignedMIPrincipalId ?? ''
output endpoint string = 'https://${app.outputs.defaultHostname}/'
