// Azure Local storage path (a folder on a Cluster Shared Volume where VM disks and config files live)
metadata description = 'Creates an Azure Local storage path on a CSV.'

@description('Storage path resource name, e.g. sp-userstorage1-vms')
param name string

param location string

@description('Full resource ID of the Azure Local custom location')
param customLocationId string

@description('Folder on a CSV, e.g. C:\\ClusterStorage\\UserStorage_1\\VMs')
param path string

param tags object = {}

resource storagePath 'Microsoft.AzureStackHCI/storageContainers@2024-01-01' = {
  name: name
  location: location
  tags: tags
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    path: path
  }
}

output id string = storagePath.id
