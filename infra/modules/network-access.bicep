@description('Site config objects read immediately before deployment; preserve unrelated settings.')
param sites array
param sqlServerName string
param sqlOutboundAddresses array
@description('Use 255.255.255.255 when bootstrap is finished; never omit an already-deployed rule.')
param bootstrapAdministratorAddress string = '255.255.255.255'

resource server 'Microsoft.Sql/servers@2025-01-01' existing = { name: sqlServerName }
resource firewall 'Microsoft.Sql/servers/firewallRules@2025-01-01' = [for (address, i) in sqlOutboundAddresses: {
  parent: server
  name: 'app-egress-${i}'
  properties: { startIpAddress: address, endIpAddress: address }
}]
resource bootstrap 'Microsoft.Sql/servers/firewallRules@2025-01-01' = {
  parent: server
  name: 'administrator-bootstrap'
  properties: { startIpAddress: bootstrapAdministratorAddress, endIpAddress: bootstrapAdministratorAddress }
}
resource configurations 'Microsoft.Web/sites/config@2025-03-01' = [for site in sites: {
  name: '${site.name}/web'
  properties: union(site.config, {
    ipSecurityRestrictionsDefaultAction: 'Deny'
    scmIpSecurityRestrictionsDefaultAction: 'Deny'
    scmIpSecurityRestrictionsUseMain: false
    ipSecurityRestrictions: map(site.allowedAddresses, (address, i) => {
      name: 'approved-${i}'
      priority: 100 + i
      action: 'Allow'
      ipAddress: address
    })
    scmIpSecurityRestrictions: map(site.administratorAddresses, (address, i) => {
      name: 'administrator-${i}'
      priority: 100 + i
      action: 'Allow'
      ipAddress: address
    })
  })
}]
