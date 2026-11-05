// Cluster-shared resources: storage paths, logical networks, VM images.
// Requires the "Azure Stack HCI Administrator" role (VM Contributor cannot create these).
targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Full resource ID of the Azure Local custom location')
param customLocationId string

@description('Storage paths: [{ name, path }]')
param storagePaths array = []

@description('Logical networks: [{ name, vmSwitchName, ipAllocationMethod, addressPrefix?, defaultGateway?, ipPoolStart?, ipPoolEnd?, dnsServers?, vlanId? }]')
param logicalNetworks array = []

@description('Marketplace images: [{ name, osType, publisher, offer, sku, version, storagePathName? }]')
param images array = []

param tags object = {}

module storage 'modules/storagePath.bicep' = [
  for sp in storagePaths: {
    name: 'sp-${sp.name}'
    params: {
      name: sp.name
      location: location
      customLocationId: customLocationId
      path: sp.path
      tags: tags
    }
  }
]

module lnets 'modules/logicalNetwork.bicep' = [
  for ln in logicalNetworks: {
    name: 'lnet-${ln.name}'
    params: {
      name: ln.name
      location: location
      customLocationId: customLocationId
      vmSwitchName: ln.vmSwitchName
      ipAllocationMethod: ln.?ipAllocationMethod ?? 'Static'
      addressPrefix: ln.?addressPrefix ?? ''
      defaultGateway: ln.?defaultGateway ?? ''
      ipPoolStart: ln.?ipPoolStart ?? ''
      ipPoolEnd: ln.?ipPoolEnd ?? ''
      dnsServers: ln.?dnsServers ?? []
      vlanId: ln.?vlanId ?? 0
      tags: tags
    }
  }
]

module imgs 'modules/marketplaceImage.bicep' = [
  for img in images: {
    name: 'img-${img.name}'
    params: {
      name: img.name
      location: location
      customLocationId: customLocationId
      osType: img.?osType ?? 'Windows'
      publisher: img.publisher
      offer: img.offer
      sku: img.sku
      version: img.version
      storagePathId: empty(img.?storagePathName ?? '')
        ? ''
        : resourceId('Microsoft.AzureStackHCI/storageContainers', img.storagePathName)
      tags: tags
    }
    dependsOn: [
      storage
    ]
  }
]

output logicalNetworkIds array = [for (ln, i) in logicalNetworks: lnets[i].outputs.id]
output imageIds array = [for (img, i) in images: imgs[i].outputs.id]
