// Azure Front Door Premium with two routes (NO WAF — explicitly out of scope).
//
//   Route 1: /direct/*  -> App Service production slot (Shared Private Link
//            via groupId 'sites'). A rule-set strips the /direct prefix
//            before forwarding so the upstream sees /<rest>.
//
//   Route 2: /*         -> nginx Container App (Shared Private Link via
//            groupId 'managedEnvironments'). nginx then forwards to either
//            the production slot or the staging slot based on path.
//
// Profile, endpoint, origin groups, origins, routes, rule-set, and
// diagnostic settings are all included.

param location string = 'global'
param tags object = {}

param frontDoorProfileName string
param frontDoorEndpointName string

@description('App Service resource ID (the parent site, NOT the slot). Used as the SPL target with groupId=sites.')
param appServiceResourceId string
@description('App Service production-slot FQDN, e.g. app-fdr-dev-xxx.azurewebsites.net.')
param appServiceHostName string

@description('Container Apps managed environment resource ID. Used as the SPL target with groupId=managedEnvironments.')
param managedEnvironmentResourceId string
@description('Container App FQDN (env-prefixed), e.g. ca-nginx-xxx.<token>.<region>.azurecontainerapps.io.')
param nginxContainerAppHostName string

@description('Log Analytics workspace resource ID for AFD diagnostic settings.')
param logAnalyticsWorkspaceId string

// SKU must be Premium for shared private link.
var sku = 'Premium_AzureFrontDoor'

// ---------------------------------------------------------------------------
// Profile + endpoint
// ---------------------------------------------------------------------------
resource profile 'Microsoft.Cdn/profiles@2024-02-01' = {
  name: frontDoorProfileName
  location: location
  sku: {
    name: sku
  }
  tags: tags
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' = {
  parent: profile
  name: frontDoorEndpointName
  location: location
  properties: {
    enabledState: 'Enabled'
  }
  tags: tags
}

// ---------------------------------------------------------------------------
// Origin group + origin: App Service (direct route)
// ---------------------------------------------------------------------------
resource ogAppService 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = {
  parent: profile
  name: 'og-appservice'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: '/healthz'
      probeRequestType: 'HEAD'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 100
    }
    sessionAffinityState: 'Disabled'
  }
}

resource originAppService 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = {
  parent: ogAppService
  name: 'origin-appservice'
  properties: {
    hostName: appServiceHostName
    originHostHeader: appServiceHostName
    httpPort: 80
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
    sharedPrivateLinkResource: {
      groupId: 'sites'
      privateLink: {
        id: appServiceResourceId
      }
      privateLinkLocation: reference(appServiceResourceId, '2023-12-01', 'Full').location
      requestMessage: 'Front Door to App Service (production slot) — created by frontdoor-routing.'
    }
  }
}

// ---------------------------------------------------------------------------
// Origin group + origin: nginx Container App (catch-all route)
// ---------------------------------------------------------------------------
resource ogNginx 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = {
  parent: profile
  name: 'og-nginx'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: '/healthz'
      probeRequestType: 'HEAD'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 100
    }
    sessionAffinityState: 'Disabled'
  }
}

resource originNginx 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = {
  parent: ogNginx
  name: 'origin-nginx'
  properties: {
    hostName: nginxContainerAppHostName
    originHostHeader: nginxContainerAppHostName
    httpPort: 80
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
    sharedPrivateLinkResource: {
      groupId: 'managedEnvironments'
      privateLink: {
        id: managedEnvironmentResourceId
      }
      privateLinkLocation: reference(managedEnvironmentResourceId, '2024-03-01', 'Full').location
      requestMessage: 'Front Door to ACA env (nginx proxy) — created by frontdoor-routing.'
    }
  }
}

// ---------------------------------------------------------------------------
// Rule set: strip "/direct" prefix before forwarding to App Service.
// ---------------------------------------------------------------------------
resource ruleSetDirect 'Microsoft.Cdn/profiles/ruleSets@2024-02-01' = {
  parent: profile
  name: 'rsStripDirect'
}

resource ruleStripDirect 'Microsoft.Cdn/profiles/ruleSets/rules@2024-02-01' = {
  parent: ruleSetDirect
  name: 'stripDirectPrefix'
  properties: {
    order: 1
    matchProcessingBehavior: 'Continue'
    conditions: []
    actions: [
      {
        name: 'UrlRewrite'
        parameters: {
          typeName: 'DeliveryRuleUrlRewriteActionParameters'
          sourcePattern: '/direct'
          destination: '/'
          preserveUnmatchedPath: true
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------
// Route 1: /direct/* -> App Service. More specific than /*, so it wins.
resource routeDirect 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: endpoint
  name: 'route-direct'
  properties: {
    originGroup: {
      id: ogAppService.id
    }
    ruleSets: [
      {
        id: ruleSetDirect.id
      }
    ]
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/direct/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
    enabledState: 'Enabled'
  }
  dependsOn: [
    originAppService
    ruleStripDirect
  ]
}

// Route 2: /* -> nginx (catch-all).
resource routeNginx 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: endpoint
  name: 'route-nginx'
  properties: {
    originGroup: {
      id: ogNginx.id
    }
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
    enabledState: 'Enabled'
  }
  dependsOn: [
    originNginx
  ]
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------
resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: profile
  name: 'afd-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'FrontDoorAccessLog',                enabled: true }
      { category: 'FrontDoorHealthProbeLog',           enabled: true }
      { category: 'FrontDoorWebApplicationFirewallLog', enabled: false }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output frontDoorProfileName string = profile.name
output frontDoorEndpointHostName string = endpoint.properties.hostName
output frontDoorEndpointResourceId string = endpoint.id
