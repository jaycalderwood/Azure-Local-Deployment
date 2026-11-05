// Azure Virtual Desktop control plane for Azure Local session hosts:
// host pool + desktop application group + workspace.
targetScope = 'resourceGroup'

@description('Host pool name')
param hostPoolName string

@description('AVD metadata region (where the host pool object lives in Azure)')
param location string = resourceGroup().location

@allowed([
  'Pooled'
  'Personal'
])
param hostPoolType string = 'Pooled'

@description('Pooled only: max users per session host')
param maxSessionLimit int = 5

param tags object = {}

var isPooled = hostPoolType == 'Pooled'

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: hostPoolName
  location: location
  tags: tags
  properties: union(
    {
      friendlyName: hostPoolName
      description: 'Azure Local session hosts - managed by Azure DevOps'
      hostPoolType: hostPoolType
      preferredAppGroupType: 'Desktop'
      validationEnvironment: false
      startVMOnConnect: false
      customRdpProperty: 'drivestoredirect:s:*;audiomode:i:0;videoplaybackmode:i:1;redirectclipboard:i:1;redirectprinters:i:1;devicestoredirect:s:*;redirectcomports:i:1;redirectsmartcards:i:1;usbdevicestoredirect:s:*;enablecredsspsupport:i:1;use multimon:i:1;'
    },
    isPooled
      ? { loadBalancerType: 'BreadthFirst', maxSessionLimit: maxSessionLimit }
      : { loadBalancerType: 'Persistent', personalDesktopAssignmentType: 'Automatic' }
  )
}

resource desktopAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: '${hostPoolName}-DAG'
  location: location
  tags: tags
  properties: {
    friendlyName: '${hostPoolName} desktop'
    applicationGroupType: 'Desktop'
    hostPoolArmPath: hostPool.id
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2024-04-03' = {
  name: '${hostPoolName}-WS'
  location: location
  tags: tags
  properties: {
    friendlyName: hostPoolName
    applicationGroupReferences: [
      desktopAppGroup.id
    ]
  }
}

output hostPoolId string = hostPool.id
output appGroupId string = desktopAppGroup.id
output workspaceId string = workspace.id
