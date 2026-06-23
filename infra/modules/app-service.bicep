// Linux S1 App Service Plan + .NET 8 web app + staging slot,
// configured for blue/green via slot-sticky app settings.
//
// Slot stickiness:
//   The names listed in 'slotConfigNames' below stay tied to the slot they
//   were set on; `az webapp deployment slot swap` does NOT carry them.
//   So after a swap, what used to be production becomes staging and the
//   SLOT_ROLE/DEPLOYMENT_COLOR values follow the slot, not the app code.

param location string
param tags object = {}

param appServicePlanName string
param appServiceName string
param slotName string = 'staging'

@description('App Service plan SKU. Standard (S1) or higher is required for deployment slots; Basic SKUs do not allow slots.')
param appServicePlanSku string = 'S1'

@description('Subnet ID for App Service regional VNet integration (delegated to Microsoft.Web/serverFarms).')
param vnetIntegrationSubnetId string

@description('Optional deployer public IP (no CIDR). When provided, allowed through the SCM/Kudu firewall so `azd deploy` can push zips while the main site stays private (PE-only).')
param myIpAddress string = ''

@description('Sticky setting names (apply to whichever slot they are set on, ignored on swap).')
var slotStickySettingNames = [
  'SLOT_ROLE'
  'DEPLOYMENT_COLOR'
  'ACTIVE_SLOT_NAME'
]

// .NET 8 on Linux
var linuxFxVersion = 'DOTNETCORE|8.0'

// ---------------------------------------------------------------------------
// Access restrictions:
//   * Main site: deny all public traffic. Front Door's shared-private-link
//     traffic arrives through the PE NIC (private), which bypasses
//     ipSecurityRestrictions entirely — so AFD still reaches the site.
//   * SCM/Kudu: deny by default, allow only the deployer's public IP so
//     `azd deploy` / `az webapp deploy` can push zips from the developer
//     machine. Without this, publicNetworkAccess=Disabled would block all
//     publishing and you'd need a jumpbox in the VNet.
// ---------------------------------------------------------------------------
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
// App Service Plan (Linux)
// ---------------------------------------------------------------------------
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: appServicePlanSku
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

// ---------------------------------------------------------------------------
// Web App — production slot
// ---------------------------------------------------------------------------
resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: appServiceName
  location: location
  tags: union(tags, { 'azd-service-name': 'app' })
  kind: 'app,linux'
  properties: {
    serverFarmId: appServicePlan.id
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
        // Build artifact-from-zip; sample app is small and stateless.
        { name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE', value: 'false' }
        { name: 'WEBSITE_RUN_FROM_PACKAGE',            value: '1' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT',      value: 'false' }
        { name: 'ASPNETCORE_ENVIRONMENT',              value: 'Production' }

        // Sticky names — values below identify this as the production slot.
        { name: 'SLOT_ROLE',        value: 'main' }
        { name: 'DEPLOYMENT_COLOR', value: 'blue' }
        { name: 'ACTIVE_SLOT_NAME', value: 'production' }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Staging slot
// ---------------------------------------------------------------------------
resource webAppSlot 'Microsoft.Web/sites/slots@2023-12-01' = {
  parent: webApp
  name: slotName
  location: location
  tags: union(tags, { 'azd-service-name': 'app' })
  kind: 'app,linux'
  properties: {
    serverFarmId: appServicePlan.id
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

        // Sticky names — values below identify this as the staging slot.
        { name: 'SLOT_ROLE',        value: 'staging' }
        { name: 'DEPLOYMENT_COLOR', value: 'green' }
        { name: 'ACTIVE_SLOT_NAME', value: 'staging' }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Mark the blue/green settings as slot-sticky.
// (slotConfigNames lives only on the parent site; the names listed here are
// applied to whichever slot has them set, and are NOT swapped.)
// ---------------------------------------------------------------------------
resource slotConfigNames 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: webApp
  name: 'slotConfigNames'
  properties: {
    appSettingNames: slotStickySettingNames
  }
  // Ensure both slots' app settings exist before we mark them sticky,
  // otherwise the API may reject names that don't yet have a value.
  dependsOn: [
    webAppSlot
  ]
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output appServiceName string = webApp.name
output appServiceResourceId string = webApp.id
output appServiceDefaultHostName string = webApp.properties.defaultHostName
output appServicePlanId string = appServicePlan.id

output slotName string = webAppSlot.name
// Slot default hostname is <site>-<slot>.azurewebsites.net (production is just <site>.azurewebsites.net).
output slotDefaultHostName string = webAppSlot.properties.defaultHostName
