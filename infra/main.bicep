targetScope = 'subscription'

@minLength(3)
@maxLength(12)
param namePrefix string
@description('Explicit Azure public-cloud region code. Verify SKU support, subscription capacity and regional costs before deployment.')
@minLength(1)
param location string
param owner string = 'ContosoDemo'
param costCentre string = 'Demo'
@minLength(36)
@maxLength(36)
param sqlAdministratorObjectId string
param sqlAdministratorLogin string
@allowed(['User', 'Group', 'Application'])
param sqlAdministratorType string = 'Group'
@minLength(36)
@maxLength(36)
param tenantId string
@minLength(1)
param notificationEmails array
@allowed(['B1', 'B2'])
param developmentSku string = 'B1'
param budgetStartDate string = utcNow('yyyy-MM-01')

var tags = {
  Owner: owner
  CostCentre: costCentre
  Project: 'ContosoFinOpsDemo'
  ManagedBy: 'Bicep'
}
var suffix = uniqueString(subscription().id, namePrefix)
var prodTags = union(tags, { Environment: 'Production', Application: 'SharedProduction' })
var devTags = union(tags, { Environment: 'Development', Application: 'DevelopmentPortal' })
var sharedTags = union(tags, { Environment: 'Shared', Application: 'SharedServices' })
resource production 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-finops-production'
  location: location
  tags: prodTags
}
resource development 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-finops-development'
  location: location
  tags: devTags
}
resource shared 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-finops-shared'
  location: location
  tags: sharedTags
}
module monitoring 'modules/monitoring.bicep' = {
  name: 'shared-monitoring'
  scope: shared
  params: { namePrefix: namePrefix, location: location, tags: sharedTags, notificationEmails: notificationEmails }
}
module productionPlan 'modules/app-service-plan.bicep' = {
  name: 'production-plan'
  scope: shared
  params: {
    name: '${namePrefix}-production-plan'
    location: location
    tags: union(tags, { Environment: 'Shared', Application: 'SharedAppHosting', WorkloadEnvironment: 'Production' })
    actionGroupId: monitoring.outputs.actionGroupId
  }
}
module developmentPlan 'modules/app-service-plan.bicep' = {
  name: 'development-plan'
  scope: development
  params: {
    name: '${namePrefix}-development-plan'
    location: location
    tags: devTags
    sku: developmentSku
    actionGroupId: monitoring.outputs.actionGroupId
  }
}
module productionSql 'modules/sql.bicep' = {
  name: 'production-sql'
  scope: production
  params: {
    name: '${namePrefix}-prod-${suffix}'
    location: location
    tags: union(tags, { Environment: 'Production', Application: 'OrdersAPI' })
    administratorObjectId: sqlAdministratorObjectId
    administratorLogin: sqlAdministratorLogin
    administratorType: sqlAdministratorType
    tenantId: tenantId
    retentionDays: 7
    backupRedundancy: 'Geo'
  }
}
module developmentSql 'modules/sql.bicep' = {
  name: 'development-sql'
  scope: development
  params: {
    name: '${namePrefix}-dev-${suffix}'
    location: location
    tags: devTags
    administratorObjectId: sqlAdministratorObjectId
    administratorLogin: sqlAdministratorLogin
    administratorType: sqlAdministratorType
    tenantId: tenantId
    retentionDays: 1
    backupRedundancy: 'Local'
  }
}
module storage 'modules/storage.bicep' = {
  name: 'shared-storage'
  scope: shared
  params: { name: '${namePrefix}${suffix}', location: location, tags: sharedTags }
}
module ordersApi 'modules/web-app.bicep' = {
  name: 'orders-api'
  scope: production
  params: {
    name: '${namePrefix}-orders-${suffix}'
    role: 'OrdersAPI'
    location: location
    tags: union(tags, { Environment: 'Production', Application: 'OrdersAPI' })
    planId: productionPlan.outputs.resourceId
    workspaceId: monitoring.outputs.workspaceId
    actionGroupId: monitoring.outputs.actionGroupId
    sqlServerName: productionSql.outputs.name
    databaseName: productionSql.outputs.databaseName
  }
}
var roles = ['CustomerPortal', 'ReportingPortal']
var appNames = ['${namePrefix}-customer-${suffix}', '${namePrefix}-reports-${suffix}']
module productionApps 'modules/web-app.bicep' = [for (role, i) in roles: {
  name: 'production-app-${i}'
  scope: production
  params: {
    name: appNames[i]
    role: role
    location: location
    tags: union(tags, { Environment: 'Production', Application: role })
    planId: productionPlan.outputs.resourceId
    workspaceId: monitoring.outputs.workspaceId
    actionGroupId: monitoring.outputs.actionGroupId
    sqlServerName: productionSql.outputs.name
    databaseName: productionSql.outputs.databaseName
    apiBaseUri: ordersApi.outputs.endpoint
    reportStorageUri: '${storage.outputs.blobEndpoint}report-exports'
  }
}]
module developmentApp 'modules/web-app.bicep' = {
  name: 'development-app'
  scope: development
  params: {
    name: '${namePrefix}-development-${suffix}'
    role: 'DevelopmentPortal'
    location: location
    tags: devTags
    planId: developmentPlan.outputs.resourceId
    workspaceId: monitoring.outputs.workspaceId
    actionGroupId: monitoring.outputs.actionGroupId
    sqlServerName: developmentSql.outputs.name
    databaseName: developmentSql.outputs.databaseName
  }
}
module reportAccess 'modules/access.bicep' = {
  name: 'report-container-access'
  scope: shared
  params: {
    storageName: storage.outputs.name
    principalId: productionApps[1].outputs.principalId
  }
}
module budgets 'modules/budgets.bicep' = {
  name: 'subscription-budgets'
  params: { notificationEmails: notificationEmails, startDate: budgetStartDate }
}
module groupBudgets 'modules/budgets.bicep' = [for (group, i) in [
  { name: production.name, amount: 8 }
  { name: development.name, amount: 18 }
  { name: shared.name, amount: 16 }
]: {
  name: 'group-budget-${i}'
  params: { notificationEmails: notificationEmails, startDate: budgetStartDate, resourceGroupName: group.name, amount: group.amount }
}]
output productionApplications array = [{
  role: 'OrdersAPI'
  name: ordersApi.outputs.name
  resourceId: ordersApi.outputs.resourceId
  principalId: ordersApi.outputs.principalId
  endpoint: ordersApi.outputs.endpoint
}, {
  role: 'CustomerPortal'
  name: productionApps[0].outputs.name
  resourceId: productionApps[0].outputs.resourceId
  principalId: productionApps[0].outputs.principalId
  endpoint: productionApps[0].outputs.endpoint
}, {
  role: 'ReportingPortal'
  name: productionApps[1].outputs.name
  resourceId: productionApps[1].outputs.resourceId
  principalId: productionApps[1].outputs.principalId
  endpoint: productionApps[1].outputs.endpoint
}]
output developmentApplication object = {
  name: developmentApp.outputs.name
  resourceId: developmentApp.outputs.resourceId
  principalId: developmentApp.outputs.principalId
  endpoint: developmentApp.outputs.endpoint
}
output sqlServers object = { production: productionSql.outputs.name, development: developmentSql.outputs.name }
output databaseName string = 'orders'
output storageAccountName string = storage.outputs.name
output developmentPlanName string = '${namePrefix}-development-plan'
