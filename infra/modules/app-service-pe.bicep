// Two private endpoints for the App Service: one for the production site
// (groupId: sites) and one for the staging slot (groupId: sites-staging,
// member name = slot name). Both registered into the
// privatelink.azurewebsites.net zone.

param location string
param tags object = {}

@description('Subnet for the private endpoints (PE network policies disabled).')
param subnetId string

@description('Web app resource ID (the parent site, not the slot).')
param appServiceResourceId string

@description('Staging slot name — must match the slot defined in app-service.bicep.')
param slotName string = 'staging'

param privateEndpointAppProdName string
param privateEndpointAppStagingName string

@description('privatelink.azurewebsites.net zone resource ID for DNS group registration.')
param privateDnsZoneId string

// ---------------------------------------------------------------------------
// Production slot PE
// ---------------------------------------------------------------------------
resource peProd 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointAppProdName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'app-prod'
        properties: {
          privateLinkServiceId: appServiceResourceId
          groupIds: ['sites']
        }
      }
    ]
  }
}

resource peProdDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: peProd
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-azurewebsites-net'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Staging slot PE — same web app, different groupId, with the slot name as
// the member.
// ---------------------------------------------------------------------------
resource peStaging 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointAppStagingName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'app-staging'
        properties: {
          privateLinkServiceId: appServiceResourceId
          groupIds: ['sites-${slotName}']
        }
      }
    ]
  }
}

resource peStagingDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: peStaging
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-azurewebsites-net'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

output peProdId string = peProd.id
output peStagingId string = peStaging.id
