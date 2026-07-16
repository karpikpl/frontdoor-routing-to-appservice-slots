// Azure Front Door Premium profile — extracted so its `frontDoorId` property
// can be consumed by downstream resources (nginx) at deploy time to enforce
// origin authentication. The full endpoint/origin/route topology lives in
// front-door.bicep and references this profile via `existing`.

param location string = 'global'
param tags object = {}

param frontDoorProfileName string

var sku = 'Premium_AzureFrontDoor'

resource profile 'Microsoft.Cdn/profiles@2024-02-01' = {
  name: frontDoorProfileName
  location: location
  sku: {
    name: sku
  }
  tags: tags
}

output name string = profile.name
output id string = profile.id

@description('Unique Front Door instance ID (GUID) that AFD injects as the X-Azure-FDID header on every request to origins. Use this to verify traffic came from THIS Front Door instance.')
output frontDoorId string = profile.properties.frontDoorId
