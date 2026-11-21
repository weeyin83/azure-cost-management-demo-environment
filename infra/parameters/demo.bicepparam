using '../main.bicep'
param namePrefix = readEnvironmentVariable('CONTOSO_PREFIX')
param sqlAdministratorObjectId = readEnvironmentVariable('CONTOSO_SQL_ADMIN_OBJECT_ID')
param sqlAdministratorLogin = readEnvironmentVariable('CONTOSO_SQL_ADMIN_NAME')
param tenantId = readEnvironmentVariable('CONTOSO_TENANT_ID')
param notificationEmails = split(readEnvironmentVariable('CONTOSO_BUDGET_EMAILS'), ',')
param developmentSku = 'B1'
