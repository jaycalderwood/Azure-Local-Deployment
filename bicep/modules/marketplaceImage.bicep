// Azure Local VM image downloaded from Azure Marketplace onto the cluster
metadata description = 'Creates an Azure Local VM image from an Azure Marketplace image.'

@description('Image resource name, e.g. img-ws2025-dc-azure-edition')
param name string

param location string

@description('Full resource ID of the Azure Local custom location')
param customLocationId string

@description('Storage path resource ID to store the image in. Empty = cluster default.')
param storagePathId string = ''

@allowed([
  'Windows'
  'Linux'
])
param osType string = 'Windows'

param publisher string = 'MicrosoftWindowsServer'
param offer string = 'WindowsServer'
param sku string = '2025-datacenter-azure-edition'

@description('Marketplace image version. List with: az vm image list --publisher <p> --offer <o> --sku <s> --all -o table')
param version string

param tags object = {}

resource image 'Microsoft.AzureStackHCI/marketplaceGalleryImages@2024-01-01' = {
  name: name
  location: location
  tags: tags
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: union({
    osType: osType
    hyperVGeneration: 'V2'
    identifier: {
      publisher: publisher
      offer: offer
      sku: sku
    }
    version: {
      name: version
    }
  }, empty(storagePathId) ? {} : { containerId: storagePathId })
}

output id string = image.id
