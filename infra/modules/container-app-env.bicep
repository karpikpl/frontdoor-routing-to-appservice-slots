// Container Apps managed environment:
//   * VNet-injected (uses snet-aca-infra)
//   * internal=true (private only, addressable via PE / VNet DNS)
//   * publicNetworkAccess=Disabled
//   * Consumption workload profile (cheapest; supports private link)
//
// Front Door connects via Shared Private Link with groupId='managedEnvironments'.

param location string
param tags object = {}

param name string

@description('Subnet delegated to Microsoft.App/environments (/23 minimum).')
param infrastructureSubnetId string

@description('Log Analytics workspace resource ID for log forwarding.')
param logAnalyticsWorkspaceId string

// Look up the LAW to read customerId / sharedKey.
var lawParts = split(logAnalyticsWorkspaceId, '/')
var lawName = last(lawParts)
var lawRg   = lawParts[length(lawParts) - 5]
var lawSub  = lawParts[2]

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: lawName
  scope: resourceGroup(lawSub, lawRg)
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    // Note: with vnetConfiguration.internal=true the env is reachable only
    // via private IP; Front Door reaches it via Shared Private Link
    // (groupId=managedEnvironments). No need for a separate
    // publicNetworkAccess flag.
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      internal: true
      infrastructureSubnetId: infrastructureSubnetId
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    zoneRedundant: false
  }
}

output id string = env.id
output name string = env.name
output defaultDomain string = env.properties.defaultDomain
output staticIp string = env.properties.staticIp
output workloadProfileName string = 'Consumption'
