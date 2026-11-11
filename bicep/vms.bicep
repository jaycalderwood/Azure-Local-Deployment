// Workload VMs. Requires "Azure Stack HCI VM Contributor" on this RG,
// plus read access to the cluster RG holding the custom location, logical networks and images.
targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Full resource ID of the Azure Local custom location')
param customLocationId string

@description('Resource group holding logical networks, images and storage paths (usually the cluster RG)')
param infraResourceGroup string

@description('Default logical network name if a VM does not set one')
param defaultLogicalNetwork string

@description('Default image name if a VM does not set one')
param defaultImage string

@description('Default storage path name. Empty = let the cluster choose.')
param defaultStoragePath string = ''

@description('VMs: [{ name, processors?, memoryMB?, ipAddress?, logicalNetwork?, image?, osType?, dataDisksGB?, domainJoin? }]')
param vms array

param adminUsername string = 'azladmin'

@secure()
param adminPassword string

param domainToJoin string = ''
param domainOUPath string = ''
param domainJoinUserName string = ''

@secure()
param domainJoinPassword string = ''

@description('DNS servers for every NIC unless a VM sets its own dnsServers')
param dnsServers array = []

param tags object = {}

module vm 'modules/vm.bicep' = [
  for v in vms: {
    name: 'vm-${v.name}'
    params: {
      name: v.name
      location: location
      customLocationId: customLocationId
      logicalNetworkId: resourceId(
        infraResourceGroup,
        'Microsoft.AzureStackHCI/logicalNetworks',
        v.?logicalNetwork ?? defaultLogicalNetwork
      )
      imageId: resourceId(
        infraResourceGroup,
        'Microsoft.AzureStackHCI/marketplaceGalleryImages',
        v.?image ?? defaultImage
      )
      storagePathId: empty(v.?storagePath ?? defaultStoragePath)
        ? ''
        : resourceId(infraResourceGroup, 'Microsoft.AzureStackHCI/storageContainers', v.?storagePath ?? defaultStoragePath)
      privateIPAddress: v.?ipAddress ?? ''
      processors: v.?processors ?? 2
      memoryMB: v.?memoryMB ?? 8192
      dynamicMemory: v.?dynamicMemory ?? false
      dataDiskSizesGB: v.?dataDisksGB ?? []
      osType: v.?osType ?? 'Windows'
      secureBootEnabled: v.?secureBoot ?? true
      sshPublicKey: v.?sshPublicKey ?? ''
      adminUsername: adminUsername
      adminPassword: adminPassword
      domainToJoin: (v.?domainJoin ?? true) ? domainToJoin : ''
      domainOUPath: domainOUPath
      domainJoinUserName: domainJoinUserName
      domainJoinPassword: domainJoinPassword
      dnsServers: v.?dnsServers ?? dnsServers
      disableIPv6: v.?disableIPv6 ?? false
      enableRdp: v.?enableRdp ?? true
      installSshExtension: v.?sshExtension ?? false
      tags: union(tags, v.?tags ?? {})
    }
  }
]

output machineIds array = [for (v, i) in vms: vm[i].outputs.machineId]
