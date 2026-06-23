// Private DNS zones + VNet links for App Service and Container Apps.
//
// App Service zone is fixed: privatelink.azurewebsites.net.
// Container Apps zone is regionalised: <env-default-domain> (already in the
// form <something>.<region>.azurecontainerapps.io), so we derive the
// privatelink zone from the env's defaultDomain at call time.

param vnetId string
param tags object = {}

@description('App Service privatelink zone — always this exact value.')
param appServiceZoneName string = 'privatelink.azurewebsites.net'

@description('ACA managed environment default domain (e.g. <token>.eastus2.azurecontainerapps.io). Used to derive the regionalised private DNS zone.')
param acaEnvDefaultDomain string

// Strip the per-env unique prefix off the default domain to get the shared
// regional zone, then prefix with privatelink.
// e.g. 'wittydune-12345.eastus2.azurecontainerapps.io'
//   -> 'eastus2.azurecontainerapps.io'
//   -> 'privatelink.eastus2.azurecontainerapps.io'
var acaDomainParts = split(acaEnvDefaultDomain, '.')
var acaRegionalZone = join(skip(acaDomainParts, 1), '.')
var acaZoneName = 'privatelink.${acaRegionalZone}'

resource appServiceZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: appServiceZoneName
  location: 'global'
  tags: tags
}

resource acaZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: acaZoneName
  location: 'global'
  tags: tags
}

resource appServiceLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: appServiceZone
  name: 'link-${uniqueString(vnetId, appServiceZoneName)}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource acaLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: acaZone
  name: 'link-${uniqueString(vnetId, acaZoneName)}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

output appServiceZoneId string = appServiceZone.id
output appServiceZoneName string = appServiceZone.name
output acaZoneId string = acaZone.id
output acaZoneName string = acaZone.name
