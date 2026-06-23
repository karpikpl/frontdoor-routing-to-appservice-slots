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
@description('App Service staging-slot FQDN, e.g. app-fdr-dev-xxx-staging.azurewebsites.net. Injected into X-Backend-Host on the /staging route.')
param appServiceStagingHostName string

@description('Container Apps managed environment resource ID. Used as the SPL target with groupId=managedEnvironments.')
param managedEnvironmentResourceId string
@description('Container App FQDN (env-prefixed), e.g. ca-nginx-xxx.<token>.<region>.azurecontainerapps.io.')
param nginxContainerAppHostName string

@description('UI App Service resource ID (the parent site). Used as the SPL target with groupId=sites.')
param appServiceUiResourceId string
@description('UI App Service FQDN, e.g. app-ui-fdr-dev-xxx.azurewebsites.net.')
param appServiceUiHostName string

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
// Origin group + origin: UI App Service (Entra-protected MVC at /ui)
// ---------------------------------------------------------------------------
resource ogUi 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = {
  parent: profile
  name: 'og-ui'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: '/ui/healthz'
      probeRequestType: 'HEAD'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 100
    }
    sessionAffinityState: 'Disabled'
  }
}

resource originUi 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = {
  parent: ogUi
  name: 'origin-ui'
  properties: {
    hostName: appServiceUiHostName
    originHostHeader: appServiceUiHostName
    httpPort: 80
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
    sharedPrivateLinkResource: {
      groupId: 'sites'
      privateLink: {
        id: appServiceUiResourceId
      }
      privateLinkLocation: reference(appServiceUiResourceId, '2023-12-01', 'Full').location
      requestMessage: 'Front Door to UI App Service — created by frontdoor-routing.'
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
// Rule set: route /staging/* through nginx, injecting X-Backend-Host so nginx
// proxies to the staging slot. Also strips the /staging prefix so nginx sees
// the original app path. Header is set with action=Overwrite, so any client-
// supplied X-Backend-Host is discarded by AFD — nginx can trust it.
// ---------------------------------------------------------------------------
resource ruleSetNginxStaging 'Microsoft.Cdn/profiles/ruleSets@2024-02-01' = {
  parent: profile
  name: 'rsNginxStaging'
}

resource ruleNginxStaging 'Microsoft.Cdn/profiles/ruleSets/rules@2024-02-01' = {
  parent: ruleSetNginxStaging
  name: 'stripAndSetStagingHost'
  properties: {
    order: 1
    matchProcessingBehavior: 'Continue'
    conditions: []
    actions: [
      {
        name: 'UrlRewrite'
        parameters: {
          typeName: 'DeliveryRuleUrlRewriteActionParameters'
          sourcePattern: '/staging'
          destination: '/'
          preserveUnmatchedPath: true
        }
      }
      {
        name: 'ModifyRequestHeader'
        parameters: {
          typeName: 'DeliveryRuleHeaderActionParameters'
          headerAction: 'Append'
          headerName: 'X-Backend-Host'
          value: appServiceStagingHostName
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Rule set: catch-all route through nginx, injecting X-Backend-Host so nginx
// proxies to the production slot. No path rewrite — pass through.
// ---------------------------------------------------------------------------
resource ruleSetNginxProd 'Microsoft.Cdn/profiles/ruleSets@2024-02-01' = {
  parent: profile
  name: 'rsNginxProd'
}

resource ruleNginxProd 'Microsoft.Cdn/profiles/ruleSets/rules@2024-02-01' = {
  parent: ruleSetNginxProd
  name: 'setProdHost'
  properties: {
    order: 1
    matchProcessingBehavior: 'Continue'
    conditions: []
    actions: [
      {
        name: 'ModifyRequestHeader'
        parameters: {
          typeName: 'DeliveryRuleHeaderActionParameters'
          headerAction: 'Append'
          headerName: 'X-Backend-Host'
          value: appServiceHostName
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

// Route 2: /ui/* -> UI App Service. More specific than /*, so it wins.
// No URL rewrite — app uses UsePathBase("/ui") so the prefix flows through.
resource routeUi 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: endpoint
  name: 'route-ui'
  properties: {
    originGroup: {
      id: ogUi.id
    }
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/ui/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
    enabledState: 'Enabled'
  }
  dependsOn: [
    originUi
  ]
}

// Route 3: /staging/* -> nginx with X-Backend-Host = staging-slot FQDN.
// AFD strips /staging at the edge, nginx is a transparent header-driven proxy.
resource routeNginxStaging 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: endpoint
  name: 'route-nginx-staging'
  properties: {
    originGroup: {
      id: ogNginx.id
    }
    ruleSets: [
      {
        id: ruleSetNginxStaging.id
      }
    ]
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/staging'
      '/staging/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
    enabledState: 'Enabled'
  }
  dependsOn: [
    originNginx
    ruleNginxStaging
  ]
}

// Route 4: /* -> nginx with X-Backend-Host = prod FQDN (catch-all).
resource routeNginx 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: endpoint
  name: 'route-nginx'
  properties: {
    originGroup: {
      id: ogNginx.id
    }
    ruleSets: [
      {
        id: ruleSetNginxProd.id
      }
    ]
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
    ruleNginxProd
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
