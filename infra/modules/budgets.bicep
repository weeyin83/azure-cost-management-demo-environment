targetScope = 'subscription'
param notificationEmails array
param startDate string
param resourceGroupName string = ''
param amount int = 42
var values = empty(resourceGroupName) ? [
  { name: 'contoso-normal-net', amount: json('41.67') }
  { name: 'contoso-guard-net', amount: json('83.33') }
] : [{ name: 'contoso-${resourceGroupName}', amount: amount }]
resource budgets 'Microsoft.Consumption/budgets@2024-08-01' = [for budget in values: {
  name: budget.name
  properties: {
    category: 'Cost'
    amount: budget.amount
    timeGrain: 'Monthly'
    timePeriod: { startDate: startDate, endDate: dateTimeAdd(startDate, 'P1Y') }
    filter: empty(resourceGroupName) ? {
      tags: { name: 'Project', operator: 'In', values: ['ContosoFinOpsDemo'] }
    } : {
      dimensions: { name: 'ResourceGroupName', operator: 'In', values: [resourceGroupName] }
    }
    notifications: {
      Actual50: { enabled: true, operator: 'GreaterThanOrEqualTo', threshold: 50, thresholdType: 'Actual', contactEmails: notificationEmails }
      Actual80: { enabled: true, operator: 'GreaterThanOrEqualTo', threshold: 80, thresholdType: 'Actual', contactEmails: notificationEmails }
      Actual100: { enabled: true, operator: 'GreaterThanOrEqualTo', threshold: 100, thresholdType: 'Actual', contactEmails: notificationEmails }
      Forecast100: { enabled: true, operator: 'GreaterThanOrEqualTo', threshold: 100, thresholdType: 'Forecasted', contactEmails: notificationEmails }
    }
  }
}]
