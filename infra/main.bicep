// frontdoor-routing — root Bicep deployment.
//
// Provisions:
//   * VNet + subnets
//   * Log Analytics workspace
//   * App Service plan + web app + staging slot (private endpoints,
//     PNA disabled, slot-sticky blue/green app settings)
//   * Private DNS for App Service (privatelink.azurewebsites.net) and ACA
//   * Container Apps managed environment (VNet-injected, internal)
//   * nginx Container App (envsubst init, routes /staging -> slot, else prod)
//   * Front Door Premium with 2 routes (App Service direct + nginx catch-all)
//     using Shared Private Link to both backends
//
// Scope: resource group (run `azd up`; azd creates the RG).

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@minLength(1)
@description('Azure region for all resources except Front Door (which is global).')
param location string = resourceGroup().location

@description('Short prefix for resource names.')
param prefix string = 'fdr'

@allowed([
  'dev'
  'uat'
  'prd'
])
@description('Environment tag.')
param env string = 'dev'

@description('AZD-managed environment name; used purely as a tag.')
param environmentName string = 'dev'

@description('Public IP (no CIDR) of the deployer. Whitelisted on the App Service SCM/Kudu endpoint so `azd deploy` can push the zip while the main site stays private. Populated by the preprovision hook in azure.yaml.')
param myIpAddress string = ''

@description('Entra app registration (single-tenant) client ID for the UI app. Created by the preprovision hook in azure.yaml.')
param entraClientId string = ''

@description('Entra tenant ID where the UI app registration lives.')
param entraTenantId string = ''

@secure()
@description('Entra app registration client secret. Populated by the preprovision hook in azure.yaml; deployed as a plain App Setting (demo-grade; move to Key Vault for production).')
param entraClientSecret string = ''

@description('Optional override for the deterministic name token. Leave default for stable per-RG hashing.')
param resourceToken string = take(uniqueString(resourceGroup().id), 8)

@description('Common tags applied to every resource.')
param tags object = {
  'azd-env-name': environmentName
  workload: 'frontdoor-routing'
  'hidden-title': 'Front Door routing demo'
  env: env
}

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------
module names 'resourcenames.bicep' = {
  name: 'names'
  params: {
    prefix: prefix
    env: env
    resourceToken: resourceToken
  }
}

// ---------------------------------------------------------------------------
// Networking
// ---------------------------------------------------------------------------
module vnet 'modules/vnet.bicep' = {
  name: 'vnet'
  params: {
    location: location
    vnetName: names.outputs.names.vnet
    subnetPeName: names.outputs.names.subnetPe
    subnetAcaInfraName: names.outputs.names.subnetAcaInfra
    subnetAspIntegrationName: names.outputs.names.subnetAspIntegration
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Monitoring
// ---------------------------------------------------------------------------
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    name: names.outputs.names.logAnalyticsWorkspace
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Container Apps environment (must exist before private DNS so we know the
// region-specific defaultDomain for the privatelink zone).
// ---------------------------------------------------------------------------
module acaEnv 'modules/container-app-env.bicep' = {
  name: 'acaEnv'
  params: {
    location: location
    name: names.outputs.names.containerAppsEnvironment
    infrastructureSubnetId: vnet.outputs.subnetAcaInfraId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Private DNS for App Service + ACA (derived from acaEnv default domain).
// ---------------------------------------------------------------------------
module privateDns 'modules/private-dns.bicep' = {
  name: 'privateDns'
  params: {
    vnetId: vnet.outputs.vnetId
    acaEnvDefaultDomain: acaEnv.outputs.defaultDomain
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// App Service (web app + staging slot, blue/green sticky settings)
// ---------------------------------------------------------------------------
module appService 'modules/app-service.bicep' = {
  name: 'appService'
  params: {
    location: location
    appServicePlanName: names.outputs.names.appServicePlan
    appServiceName: names.outputs.names.appService
    slotName: names.outputs.names.appServiceSlot
    vnetIntegrationSubnetId: vnet.outputs.subnetAspIntegrationId
    myIpAddress: myIpAddress
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// App Service private endpoints (sites + sites-staging)
// ---------------------------------------------------------------------------
module appServicePe 'modules/app-service-pe.bicep' = {
  name: 'appServicePe'
  params: {
    location: location
    subnetId: vnet.outputs.subnetPeId
    appServiceResourceId: appService.outputs.appServiceResourceId
    slotName: appService.outputs.slotName
    privateEndpointAppProdName: names.outputs.names.privateEndpointAppProd
    privateEndpointAppStagingName: names.outputs.names.privateEndpointAppStaging
    privateDnsZoneId: privateDns.outputs.appServiceZoneId
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// nginx Container App (depends on App Service hostnames + ACA env)
// ---------------------------------------------------------------------------
module nginxApp 'modules/nginx-container-app.bicep' = {
  name: 'nginxApp'
  params: {
    location: location
    name: names.outputs.names.nginxContainerApp
    containerAppsEnvironmentId: acaEnv.outputs.id
    workloadProfileName: acaEnv.outputs.workloadProfileName
    tags: tags
  }
  // No longer depends on App Service hostnames — AFD injects them per-request.
  dependsOn: []
}

// ---------------------------------------------------------------------------
// UI web app (ASP.NET MVC + Entra Auth) — same App Service Plan, no slot.
// ---------------------------------------------------------------------------
module appServiceUi 'modules/app-service-ui.bicep' = {
  name: 'appServiceUi'
  params: {
    location: location
    appServicePlanId: appService.outputs.appServicePlanId
    appServiceName: names.outputs.names.appServiceUi
    peSubnetId: vnet.outputs.subnetPeId
    vnetIntegrationSubnetId: vnet.outputs.subnetAspIntegrationId
    privateEndpointName: names.outputs.names.privateEndpointAppUi
    privateDnsZoneId: privateDns.outputs.appServiceZoneId
    myIpAddress: myIpAddress
    entraClientId: entraClientId
    entraTenantId: entraTenantId
    entraClientSecret: entraClientSecret
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Front Door Premium (no WAF)
// ---------------------------------------------------------------------------
module frontDoor 'modules/front-door.bicep' = {
  name: 'frontDoor'
  params: {
    frontDoorProfileName: names.outputs.names.frontDoorProfile
    frontDoorEndpointName: names.outputs.names.frontDoorEndpoint
    appServiceResourceId: appService.outputs.appServiceResourceId
    appServiceHostName: appService.outputs.appServiceDefaultHostName
    appServiceStagingHostName: appService.outputs.slotDefaultHostName
    managedEnvironmentResourceId: acaEnv.outputs.id
    nginxContainerAppHostName: nginxApp.outputs.fqdn
    appServiceUiResourceId: appServiceUi.outputs.appServiceResourceId
    appServiceUiHostName: appServiceUi.outputs.appServiceDefaultHostName
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Outputs — automatically surfaced as env vars to azd hooks.
// ---------------------------------------------------------------------------
output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = resourceGroup().name

output AFD_ENDPOINT_HOSTNAME string = frontDoor.outputs.frontDoorEndpointHostName
output AFD_PROFILE_NAME      string = frontDoor.outputs.frontDoorProfileName

output APP_SERVICE_NAME              string = appService.outputs.appServiceName
output APP_SERVICE_DEFAULT_HOSTNAME  string = appService.outputs.appServiceDefaultHostName
output APP_SERVICE_SLOT_NAME         string = appService.outputs.slotName
output APP_SERVICE_SLOT_HOSTNAME     string = appService.outputs.slotDefaultHostName

output CONTAINER_APPS_ENVIRONMENT_NAME    string = acaEnv.outputs.name
output CONTAINER_APPS_ENVIRONMENT_DOMAIN  string = acaEnv.outputs.defaultDomain
output NGINX_CONTAINER_APP_NAME           string = nginxApp.outputs.name
output NGINX_CONTAINER_APP_FQDN           string = nginxApp.outputs.fqdn

output UI_APP_SERVICE_NAME             string = appServiceUi.outputs.appServiceName
output UI_APP_SERVICE_DEFAULT_HOSTNAME string = appServiceUi.outputs.appServiceDefaultHostName
output AZURE_CLIENT_ID                 string = entraClientId
output AZURE_TENANT_ID                 string = entraTenantId

output VNET_NAME string = vnet.outputs.vnetName
