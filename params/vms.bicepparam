using '../bicep/vms.bicep'

param location = 'eastus'
param customLocationId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/Infrastructure/providers/Microsoft.ExtendedLocation/customLocations/my-custom-location'
param infraResourceGroup = 'Infrastructure'

// Existing cluster resources
param defaultLogicalNetwork = 'ccsln'
param defaultImage = 'server2025'
param defaultStoragePath = 'UserStorage1-00000000000000000000000000000000'

param adminUsername = 'azladmin'
param adminPassword = readEnvironmentVariable('VM_ADMIN_PASSWORD')

// Domain join (used only by VMs that don't set domainJoin: false)
param domainToJoin = 'contoso.com'
param domainOUPath = 'OU=AzureLocal,DC=contoso,DC=com'
param domainJoinUserName = 'svc-domainjoin'  // join-only account; password lives in Key Vault (domainJoinPassword)
param domainJoinPassword = readEnvironmentVariable('DOMAIN_JOIN_PASSWORD', '')

// AD01 - needed for domain join
param dnsServers = [
  '10.1.10.10'
]

param tags = {
  managedBy: 'azure-devops'
}

// VMs managed through Git (merge to main -> AzureLocal-Deploy). For one-off VMs use the New VM form.
//
// No ipAddress = Azure Local picks the next free IP from ccsln's pool (10.1.10.75-.100).
// To pin one, add  ipAddress: '10.1.10.x'  with x inside the pool and not already used.
// Removing a VM from this list does NOT delete it.
// After a VM exists, its NIC settings (IP, DNS, network, NSG) can't change - only CPU/memory/disks.
//
// Examples:
//   {                                   // Windows (default osType)
//     name: 'APP01'                     // Windows: max 15 characters
//     processors: 4
//     memoryMB: 8192
//     disableIPv6: true
//     dataDisksGB: [ 64 ]
//   }
//   {                                   // Linux
//     name: 'ubuntu-web-01'             // Linux: max 54 characters
//     osType: 'Linux'
//     image: '<your Linux image name>'  // e.g. the Ubuntu image you added to the cluster
//     sshPublicKey: 'ssh-ed25519 AAAA... you@pc'   // optional; password sign-in also works
//     domainJoin: false                 // domain join is Windows-only
//     disableIPv6: true
//   }
// enableRdp (default true) means RDP + ping on Windows and SSH on Linux.
// sshExtension: true installs the OpenSSH for Windows - Azure Arc extension (Windows) so you can
// connect with: az ssh arc --resource-group Infrastructure --name <vm> --local-user azladmin
param vms = []
