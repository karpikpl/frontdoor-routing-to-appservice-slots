// Log Analytics workspace used by AFD, App Service, and the Container Apps env.

param location string
param name string
param tags object = {}

@description('Retention in days — 30 is the default free tier.')
param retentionInDays int = 30

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      // Required for Container Apps managed env to attach via shared key.
      disableLocalAuth: false
    }
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output customerId string = workspace.properties.customerId
