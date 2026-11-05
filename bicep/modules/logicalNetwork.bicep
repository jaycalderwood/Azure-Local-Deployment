// Azure Local logical network (maps to a Hyper-V VM switch on the cluster, optionally tagged with a VLAN)
metadata description = 'Creates an Azure Local logical network (static or DHCP).'

@description('Logical network name, e.g. lnet-mgmt-static')
param name string

@description('Azure region the Azure Local instance is registered in, e.g. eastus')
param location string

@description('Full resource ID of the Azure Local custom location')
param customLocationId string

@description('Name of the Hyper-V VM switch on the cluster nodes. Find it with Get-VMSwitch on a node, e.g. "ConvergedSwitch(compute_management)"')
param vmSwitchName string

@allowed([
  'Static'
  'Dynamic'
])
@description('Static = Azure Local hands out IPs from ipPoolStart/ipPoolEnd. Dynamic = your existing DHCP server does.')
param ipAllocationMethod string = 'Static'

@description('Subnet CIDR (Static only), e.g. 10.1.10.0/24')
param addressPrefix string = ''

@description('Default gateway (Static only)')
param defaultGateway string = ''

@description('First IP Azure Local may assign to VMs (Static only)')
param ipPoolStart string = ''

@description('Last IP Azure Local may assign to VMs (Static only)')
param ipPoolEnd string = ''

@description('DNS servers handed to VMs')
param dnsServers array = []

@description('VLAN ID. 0 = untagged.')
param vlanId int = 0

@description('Resource ID of an Azure Local network security group to attach to the subnet. Empty = none.')
param nsgId string = ''

param tags object = {}

var isStatic = ipAllocationMethod == 'Static'

var staticSubnetProperties = {
  addressPrefix: addressPrefix
  ipAllocationMethod: 'Static'
  ipPools: [
    {
      start: ipPoolStart
      end: ipPoolEnd
    }
  ]
  routeTable: {
    properties: {
      routes: [
        {
          name: 'default-route'
          properties: {
            addressPrefix: '0.0.0.0/0'
            nextHopIpAddress: defaultGateway
          }
        }
      ]
    }
  }
}

var dynamicSubnetProperties = {
  ipAllocationMethod: 'Dynamic'
}

var vlanProperties = vlanId > 0 ? { vlan: vlanId } : {}
var nsgProperties = empty(nsgId) ? {} : { networkSecurityGroup: { id: nsgId } }

// 2025-06-01-preview: accepts networkSecurityGroup on the subnet
resource logicalNetwork 'Microsoft.AzureStackHCI/logicalNetworks@2025-06-01-preview' = {
  name: name
  location: location
  tags: tags
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    vmSwitchName: vmSwitchName
    dhcpOptions: empty(dnsServers) ? null : {
      dnsServers: dnsServers
    }
    subnets: [
      {
        name: '${name}-subnet'
        properties: union(isStatic ? staticSubnetProperties : dynamicSubnetProperties, vlanProperties, nsgProperties)
      }
    ]
  }
}

output id string = logicalNetwork.id
output name string = logicalNetwork.name
