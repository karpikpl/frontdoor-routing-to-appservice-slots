// Deterministic naming for all resources.
//
// We use a single 'resourceToken' (hash from main.bicep, typically
// uniqueString(resourceGroup().id)) appended to short, predictable
// prefixes so names stay globally unique without being unreadable.

@description('Short prefix for all resources (e.g. fdr = front-door-routing).')
param prefix string = 'fdr'

@description('Environment tag (dev | uat | prd).')
param env string = 'dev'

@description('Short hash used to make globally-unique names unique.')
param resourceToken string

var stem = '${prefix}-${env}-${resourceToken}'

@description('Names produced for callers to consume. Group by resource family.')
output names object = {
  vnet:                    'vnet-${stem}'
  subnetPe:                'snet-pe'
  subnetAcaInfra:          'snet-aca-infra'
  subnetAspIntegration:    'snet-asp-vnetint'

  logAnalyticsWorkspace:   'log-${stem}'

  appServicePlan:          'asp-${stem}'
  appService:              'app-${stem}'
  appServiceSlot:          'staging'

  privateEndpointAppProd:    'pe-app-prod-${stem}'
  privateEndpointAppStaging: 'pe-app-staging-${stem}'
  privateEndpointAppUi:      'pe-app-ui-${stem}'

  appServiceUi:              'app-ui-${stem}'

  // ACA env names have a 32-char hard limit; keep this short.
  containerAppsEnvironment: 'cae-${stem}'
  nginxContainerApp:        'ca-nginx-${stem}'

  frontDoorProfile:         'afd-${stem}'
  // AFD endpoint names must be globally unique and DNS-safe.
  frontDoorEndpoint:        'afd-ep-${stem}'

  privateDnsAppService:     'privatelink.azurewebsites.net'
  // ACA private DNS zone is regionalised — caller passes the region.
  privateDnsAcaPrefix:      'privatelink'
}
