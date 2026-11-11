// One VM from the "New VM" pipeline form. The pipeline resolves names to resource IDs first.
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param customLocationId string

@description('Windows: max 15 characters (checked by the pipeline). Linux: max 54 (Arc machine name limit).')
@maxLength(54)
param name string
param processors int = 2
param memoryMB int = 8192

@description('Empty = next free IP from the logical network pool')
param ipAddress string = ''

param logicalNetworkId string
param imageId string
param storagePathId string = ''

@description('Empty = no NSG on the NIC')
param nsgId string = ''

@description('Sizes in GB; [] for none')
param dataDisksGB array = []

param adminUsername string = 'azladmin'

@secure()
param adminPassword string

param joinDomain bool = true
param domainToJoin string = ''
param domainOUPath string = ''
param domainJoinUserName string = ''

@secure()
param domainJoinPassword string = ''

param dnsServers array = []
param disableIPv6 bool = false
param enableRdp bool = true

@allowed([
  'Windows'
  'Linux'
])
param osType string = 'Windows'

@description('Linux only: SSH public key; empty = password only')
param sshPublicKey string = ''

param secureBoot bool = true

@description('Azure Arc SSH extension (Windows) / make sure sshd is on (Linux)')
param installSshExtension bool = false

param tags object = {}

module vm 'modules/vm.bicep' = {
  name: 'vm-${name}'
  params: {
    name: name
    location: location
    customLocationId: customLocationId
    logicalNetworkId: logicalNetworkId
    imageId: imageId
    storagePathId: storagePathId
    nsgId: nsgId
    privateIPAddress: ipAddress
    processors: processors
    memoryMB: memoryMB
    dataDiskSizesGB: dataDisksGB
    adminUsername: adminUsername
    adminPassword: adminPassword
    domainToJoin: joinDomain ? domainToJoin : ''
    domainOUPath: domainOUPath
    domainJoinUserName: domainJoinUserName
    domainJoinPassword: domainJoinPassword
    dnsServers: dnsServers
    disableIPv6: disableIPv6
    enableRdp: enableRdp
    osType: osType
    sshPublicKey: sshPublicKey
    secureBootEnabled: secureBoot
    installSshExtension: installSshExtension
    tags: tags
  }
}

output machineId string = vm.outputs.machineId
output nicId string = vm.outputs.nicId
