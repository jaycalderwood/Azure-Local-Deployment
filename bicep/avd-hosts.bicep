// AVD session hosts on Azure Local: N Arc VMs that install the AVD agent with a registration
// token and join the domain. The pipeline creates the host pool and token first.
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param customLocationId string

@description('Session host names, e.g. [ "AVD-01", "AVD-02" ]')
param hostNames array

param processors int = 4
param memoryMB int = 16384

param logicalNetworkId string
param imageId string
param storagePathId string = ''
param nsgId string = ''

param adminUsername string = 'azladmin'

@description('Map of host name -> local admin password')
@secure()
param adminPasswords object

@secure()
param avdRegistrationToken string

param domainToJoin string
param domainOUPath string = ''
param domainJoinUserName string

@secure()
param domainJoinPassword string

param dnsServers array = []
param disableIPv6 bool = false

param tags object = {}

module hosts 'modules/vm.bicep' = [
  for h in hostNames: {
    name: 'avd-${h}'
    params: {
      name: h
      location: location
      customLocationId: customLocationId
      logicalNetworkId: logicalNetworkId
      imageId: imageId
      storagePathId: storagePathId
      nsgId: nsgId
      processors: processors
      memoryMB: memoryMB
      adminUsername: adminUsername
      adminPassword: adminPasswords[h]
      avdRegistrationToken: avdRegistrationToken
      enableRdp: true
      disableIPv6: disableIPv6
      dnsServers: dnsServers
      domainToJoin: domainToJoin
      domainOUPath: domainOUPath
      domainJoinUserName: domainJoinUserName
      domainJoinPassword: domainJoinPassword
      tags: tags
    }
  }
]

output machineIds array = [for (h, i) in hostNames: hosts[i].outputs.machineId]
