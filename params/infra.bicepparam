using '../bicep/infra.bicep'

// Cluster-shared resources. The cluster already has:
//   logical networks : ccsln (10.1.10.0/24, pool .75-.100), cluster-infra-lnet
//   images           : server2025, win11
//   storage paths    : UserStorage1-00000000000000000000000000000000, UserStorage2-00000000000000000000000000000000
// The arrays below are empty, so this stage creates nothing until you add an entry.

param location = 'eastus'
param customLocationId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/Infrastructure/providers/Microsoft.ExtendedLocation/customLocations/my-custom-location'

param tags = {
  managedBy: 'azure-devops'
}

param storagePaths = []

param logicalNetworks = []
// Example - a new VLAN served by DHCP (get vmSwitchName from Get-VMSwitch on AZL01):
// {
//   name: 'lnet-vlan20-dhcp'
//   vmSwitchName: 'ConvergedSwitch(compute_management)'
//   ipAllocationMethod: 'Dynamic'
//   vlanId: 20
// }

param images = []
// Example - another Marketplace image:
// {
//   name: 'img-ws2022-dc-azure-edition'
//   osType: 'Windows'
//   publisher: 'MicrosoftWindowsServer'
//   offer: 'WindowsServer'
//   sku: '2022-datacenter-azure-edition'
//   version: '<from az vm image list ... --all>'
//   storagePathName: 'UserStorage1-00000000000000000000000000000000'
// }
