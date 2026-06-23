// VNet with subnets for:
//   * snet-pe              — App Service private endpoints (no delegation)
//   * snet-aca-infra       — Container Apps env infra subnet
//                              (delegation: Microsoft.App/environments, /23 min)
//   * snet-asp-vnetint     — App Service regional VNet integration
//                              (delegation: Microsoft.Web/serverFarms, /27 ok)
//
// Address space is small and self-contained — adjust if peering into a hub
// later.

param location string
param vnetName string
param addressSpace string = '10.30.0.0/16'

@description('Subnet for App Service private endpoints.')
param subnetPeName string = 'snet-pe'
param subnetPePrefix string = '10.30.0.0/27'

@description('Container Apps environment infrastructure subnet (Microsoft.App/environments delegation, /23 minimum).')
param subnetAcaInfraName string = 'snet-aca-infra'
param subnetAcaInfraPrefix string = '10.30.2.0/23'

@description('Subnet delegated to App Service Plan for regional VNet integration.')
param subnetAspIntegrationName string = 'snet-asp-vnetint'
param subnetAspIntegrationPrefix string = '10.30.4.0/27'

param tags object = {}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressSpace]
    }
    subnets: [
      {
        name: subnetPeName
        properties: {
          addressPrefixes: [subnetPePrefix]
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
      {
        name: subnetAcaInfraName
        properties: {
          addressPrefixes: [subnetAcaInfraPrefix]
          delegations: [
            {
              name: 'aca-delegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: subnetAspIntegrationName
        properties: {
          addressPrefixes: [subnetAspIntegrationPrefix]
          delegations: [
            {
              name: 'asp-delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name

// Direct-reference outputs save callers from string-concat for resource IDs.
output subnetPeId string = '${vnet.id}/subnets/${subnetPeName}'
output subnetAcaInfraId string = '${vnet.id}/subnets/${subnetAcaInfraName}'
output subnetAspIntegrationId string = '${vnet.id}/subnets/${subnetAspIntegrationName}'
