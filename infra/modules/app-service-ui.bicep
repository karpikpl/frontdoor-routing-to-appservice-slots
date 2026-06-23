// UI web app (ASP.NET MVC + Entra Auth) — runs on the SAME App Service Plan
// as the main app, no slot. Reached privately via Front Door + Shared Private
// Link (groupId = sites). Path prefix /ui is owned by AFD route; the app uses
// UsePathBase("/ui") so generated URLs (including the OIDC redirect URI)
// include the prefix.

param location string
param tags object = {}

@description('Reuse the existing App Service Plan (from app-service.bicep).')
param appServicePlanId string

@description('Web app name for the UI service.')
param appServiceName string

@description('Subnet for the private endpoint.')
param peSubnetId string

@description('Subnet for App Service regional VNet integration.')
param vnetIntegrationSubnetId string

@description('PE name for the UI web app.')
param privateEndpointName string

@description('privatelink.azurewebsites.net zone resource ID for DNS registration.')
param privateDnsZoneId string

@description('Optional deployer public IP (no CIDR). Allowed through SCM/Kudu firewall.')
param myIpAddress string = ''

@description('Entra app registration (single-tenant) client ID.')
param entraClientId string

@description('Entra tenant ID.')
param entraTenantId string

@secure()
@description('Entra app registration client secret (created by preprovision hook).')
param entraClientSecret string

var linuxFxVersion = 'DOTNETCORE|8.0'

var mainIpRestrictions = [
  {
    ipAddress: 'Any'
    action: 'Deny'
    priority: 2147483647
    name: 'Deny all public'
    description: 'AFD reaches site via private endpoint; no public ingress.'
  }
]
var scmIpRestrictions = empty(myIpAddress) ? [] : [
  {
    ipAddress: '${myIpAddress}/32'
    action: 'Allow'
    priority: 100
    name: 'Allow deployer IP'
    description: 'Lets azd deploy push zips to Kudu.'
  }
]

// ---------------------------------------------------------------------------
// Web app
// ---------------------------------------------------------------------------
resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: appServiceName
  location: location
  tags: union(tags, { 'azd-service-name': 'ui' })
  kind: 'app,linux'
  properties: {
    serverFarmId: appServicePlanId
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    virtualNetworkSubnetId: vnetIntegrationSubnetId
    siteConfig: {
      linuxFxVersion: linuxFxVersion
      alwaysOn: true
      http20Enabled: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: true
      ipSecurityRestrictions: mainIpRestrictions
      ipSecurityRestrictionsDefaultAction: 'Deny'
      scmIpSecurityRestrictions: scmIpRestrictions
      scmIpSecurityRestrictionsDefaultAction: 'Deny'
      scmIpSecurityRestrictionsUseMain: false
      appSettings: [
        { name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE', value: 'false' }
        { name: 'WEBSITE_RUN_FROM_PACKAGE',            value: '1' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT',      value: 'false' }
        { name: 'ASPNETCORE_ENVIRONMENT',              value: 'Production' }
        // ASP.NET respects ASPNETCORE_FORWARDEDHEADERS_ENABLED but we wire
        // ForwardedHeaders explicitly in Program.cs so X-Forwarded-Host is
        // honored too (the default options omit it).

        // Entra config consumed by Microsoft.Identity.Web via configuration
        // section "AzureAd" — double-underscore = nested config key.
        { name: 'AzureAd__Instance',  value: environment().authentication.loginEndpoint }
        { name: 'AzureAd__TenantId',  value: entraTenantId }
        { name: 'AzureAd__ClientId',  value: entraClientId }
        #disable-next-line use-secure-value-for-secure-inputs
        { name: 'AzureAd__ClientSecret', value: entraClientSecret }
        { name: 'AzureAd__CallbackPath', value: '/signin-oidc' }
        { name: 'AzureAd__SignedOutCallbackPath', value: '/signout-callback-oidc' }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Private endpoint for the UI web app (groupId: sites).
// ---------------------------------------------------------------------------
resource pe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'ui'
        properties: {
          privateLinkServiceId: webApp.id
          groupIds: ['sites']
        }
      }
    ]
  }
}

resource peDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: pe
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

output appServiceName string = webApp.name
output appServiceResourceId string = webApp.id
output appServiceDefaultHostName string = webApp.properties.defaultHostName
