// One Azure Local VM (Windows or Linux): Arc machine + NIC + data disks + VM instance
// + guest configuration (remote access / IPv6 / AVD agent) + optional AD domain join (Windows)
metadata description = 'Deploys a single Azure Local VM enabled by Azure Arc (Windows or Linux).'

@description('VM name. Used for the Arc machine resource and the guest computer name. Windows: max 15 characters (checked by the pipeline); Linux: max 54 (Arc machine name limit).')
@maxLength(54)
param name string

param location string

@description('Full resource ID of the Azure Local custom location')
param customLocationId string

@description('Resource ID of the logical network the NIC attaches to')
param logicalNetworkId string

@description('Static IP for the NIC. Leave empty on a DHCP logical network, or to let a static logical network pick from its pool.')
param privateIPAddress string = ''

@description('Resource ID of the VM image (marketplaceGalleryImages or galleryImages)')
param imageId string

@description('Storage path resource ID for VM config and disks. Empty = cluster picks one.')
param storagePathId string = ''

param processors int = 2
param memoryMB int = 8192

@description('Enable dynamic memory; memoryMB becomes startup memory')
param dynamicMemory bool = false
param dynamicMemoryMinMB int = 2048
param dynamicMemoryMaxMB int = 16384

@description('Sizes in GB of data disks to create and attach, e.g. [ 64, 128 ]')
param dataDiskSizesGB array = []

@allowed([
  'Windows'
  'Linux'
])
param osType string = 'Windows'

param adminUsername string

@secure()
param adminPassword string

@description('Linux only: SSH public key for adminUsername. Password sign-in stays enabled as well.')
param sshPublicKey string = ''

@description('Gen2 secure boot. Marketplace Windows and Ubuntu images are signed; turn off for unsigned Linux images that will not boot.')
param secureBootEnabled bool = true
param enableTPM bool = true

@description('AD DNS domain to join, e.g. contoso.com. Empty = no domain join.')
param domainToJoin string = ''

@description('Optional OU, e.g. OU=Servers,DC=contoso,DC=com')
param domainOUPath string = ''

@description('Account allowed to join computers (sAMAccountName, no domain prefix)')
param domainJoinUserName string = ''

@secure()
param domainJoinPassword string = ''

@description('DNS servers set on the NIC. Domain join needs these to point at a domain controller.')
param dnsServers array = []

@description('Turn off IPv6. Windows: unbind it and set DisabledComponents=0xFF (runs before domain join). Linux: sysctl, persistent.')
param disableIPv6 bool = false

@description('Remote access. Windows: turn on Remote Desktop and open its firewall rules plus ICMP echo. Linux: make sure SSH is enabled and running.')
param enableRdp bool = true

@description('Azure Arc SSH: Windows gets the OpenSSH for Windows - Azure Arc extension; Linux uses its own sshd (made sure it is enabled). Connect with: az ssh arc --resource-group <rg> --name <vm> --local-user <user>')
param installSshExtension bool = false

@description('Resource ID of an Azure Local network security group to attach to the NIC. Empty = none.')
param nsgId string = ''

@description('AVD only: host pool registration token. When set, the AVD agent + boot loader are installed and registered.')
@secure()
param avdRegistrationToken string = ''

param tags object = {}

var extendedLocation = {
  type: 'CustomLocation'
  name: customLocationId
}

var isWindows = osType == 'Windows'
var isLinux = !isWindows
var useSsh = isLinux && !empty(sshPublicKey)

// ---------- Arc machine (the parent "VM" resource you see in the portal) ----------
resource machine 'Microsoft.HybridCompute/machines@2023-10-03-preview' = {
  name: name
  location: location
  kind: 'HCI'
  identity: {
    type: 'SystemAssigned'
  }
  tags: tags
}

// ---------- Network interface ----------
// 2025-06-01-preview: first API version used here that accepts networkSecurityGroup on the NIC
resource nic 'Microsoft.AzureStackHCI/networkInterfaces@2025-06-01-preview' = {
  name: '${name}-nic01'
  location: location
  tags: tags
  extendedLocation: extendedLocation
  properties: {
    dnsSettings: empty(dnsServers) ? null : {
      dnsServers: dnsServers
    }
    networkSecurityGroup: empty(nsgId) ? null : {
      id: nsgId
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: union(
          {
            subnet: {
              id: logicalNetworkId
            }
          },
          empty(privateIPAddress) ? {} : { privateIPAddress: privateIPAddress }
        )
      }
    ]
  }
}

// ---------- Data disks ----------
resource dataDisks 'Microsoft.AzureStackHCI/virtualHardDisks@2024-01-01' = [
  for (sizeGB, i) in dataDiskSizesGB: {
    name: '${name}-data${padLeft(string(i + 1), 2, '0')}'
    location: location
    tags: tags
    extendedLocation: extendedLocation
    properties: union(
      {
        diskSizeGB: sizeGB
        dynamic: true
      },
      empty(storagePathId) ? {} : { containerId: storagePathId }
    )
  }
]

// ---------- OS profile ----------
var windowsOsProfile = {
  adminUsername: adminUsername
  adminPassword: adminPassword
  computerName: name
  windowsConfiguration: {
    provisionVMAgent: true
    provisionVMConfigAgent: true
  }
}

var linuxOsProfile = {
  adminUsername: adminUsername
  adminPassword: adminPassword
  computerName: name
  linuxConfiguration: union(
    {
      provisionVMAgent: true
      provisionVMConfigAgent: true
      disablePasswordAuthentication: false   // password + optional SSH key (CLI: --authentication-type all)
    },
    useSsh
      ? {
          ssh: {
            publicKeys: [
              {
                keyData: sshPublicKey
                path: '/home/${adminUsername}/.ssh/authorized_keys'
              }
            ]
          }
        }
      : {}
  )
}

var hardwareProfile = union(
  {
    vmSize: 'Custom'
    processors: processors
    memoryMB: memoryMB
  },
  dynamicMemory
    ? {
        dynamicMemoryConfig: {
          minimumMemoryMB: dynamicMemoryMinMB
          maximumMemoryMB: dynamicMemoryMaxMB
          targetMemoryBuffer: 20
        }
      }
    : {}
)

// ---------- VM instance (extension resource on the Arc machine) ----------
resource vm 'Microsoft.AzureStackHCI/virtualMachineInstances@2024-01-01' = {
  name: 'default'
  scope: machine
  extendedLocation: extendedLocation
  properties: {
    hardwareProfile: hardwareProfile
    osProfile: isWindows ? windowsOsProfile : linuxOsProfile
    storageProfile: {
      imageReference: {
        id: imageId
      }
      dataDisks: [for (sizeGB, i) in dataDiskSizesGB: { id: dataDisks[i].id }]
      vmConfigStoragePathId: empty(storagePathId) ? null : storagePathId
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    securityProfile: {
      enableTPM: enableTPM
      uefiSettings: {
        secureBootEnabled: secureBootEnabled
      }
    }
  }
}

// ---------- Optional AD domain join (Windows) ----------
resource domainJoin 'Microsoft.HybridCompute/machines/extensions@2023-10-03-preview' = if (isWindows && !empty(domainToJoin)) {
  parent: machine
  name: 'joindomain'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      name: domainToJoin
      OUPath: domainOUPath
      User: '${domainToJoin}\\${domainJoinUserName}'
      Restart: true
      Options: 3
    }
    protectedSettings: {
      Password: domainJoinPassword
    }
  }
  dependsOn: [
    vm
    guestConfig // RDP / IPv6 / AVD agent first; the domain-join reboot then makes the IPv6 change stick
    openSsh     // extensions on one machine run one at a time: guest script -> OpenSSH -> domain join
  ]
}

// ---------- Guest configuration (Windows): RDP, IPv6, AVD agent ----------
// One CustomScriptExtension per machine is allowed, so every guest tweak runs in this single script.
// It runs BEFORE the domain join; the join's reboot then makes the IPv6 registry change permanent.
var rdpSteps = [
  'Set-ItemProperty -Path \'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server\' -Name fDenyTSConnections -Value 0'
  'Enable-NetFirewallRule -Name \'RemoteDesktop-UserMode-In-TCP\',\'RemoteDesktop-UserMode-In-UDP\',\'FPS-ICMP4-ERQ-In\' -ErrorAction SilentlyContinue'
  'Enable-NetFirewallRule -DisplayGroup \'Remote Desktop\' -ErrorAction SilentlyContinue'
]
var ipv6Steps = [
  'Get-NetAdapter | Disable-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue'
  'New-ItemProperty -Path \'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters\' -Name DisabledComponents -PropertyType DWord -Value 255 -Force | Out-Null'
]
var avdSteps = [
  '[Net.ServicePointManager]::SecurityProtocol = \'Tls12\''
  '$d = \'C:\\AVDAgent\'; New-Item -ItemType Directory -Force -Path $d | Out-Null'
  'Invoke-WebRequest -UseBasicParsing -Uri \'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv\' -OutFile (Join-Path $d \'agent.msi\')'
  'Invoke-WebRequest -UseBasicParsing -Uri \'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH\' -OutFile (Join-Path $d \'boot.msi\')'
  '$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList \'/i\',(Join-Path $d \'agent.msi\'),\'/quiet\',\'/norestart\',(\'REGISTRATIONTOKEN=\' + \'${avdRegistrationToken}\'); if ($p.ExitCode -ne 0) { exit $p.ExitCode }'
  '$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList \'/i\',(Join-Path $d \'boot.msi\'),\'/quiet\',\'/norestart\'; if ($p.ExitCode -ne 0) { exit $p.ExitCode }'
]
var guestSteps = concat(
  enableRdp ? rdpSteps : [],
  disableIPv6 ? ipv6Steps : [],
  empty(avdRegistrationToken) ? [] : avdSteps
)
var runGuestConfig = isWindows && !empty(guestSteps)
var guestCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "${join(guestSteps, '; ')}"'

resource guestConfig 'Microsoft.HybridCompute/machines/extensions@2023-10-03-preview' = if (runGuestConfig) {
  parent: machine
  name: 'CustomScriptExtension'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: guestCommand
    }
  }
  dependsOn: [
    vm
  ]
}

// ---------- Guest configuration (Linux): SSH, IPv6 ----------
// Linux counterpart of the script above, run by the Linux Custom Script extension through the Arc agent.
var linuxSshSteps = [
  '(systemctl enable --now ssh || systemctl enable --now sshd) >/dev/null 2>&1 || true'
]
var linuxIpv6Steps = [
  'printf \'net.ipv6.conf.all.disable_ipv6 = 1\\nnet.ipv6.conf.default.disable_ipv6 = 1\\nnet.ipv6.conf.lo.disable_ipv6 = 1\\n\' > /etc/sysctl.d/99-disable-ipv6.conf'
  'sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null'
]
var linuxSteps = concat((enableRdp || installSshExtension) ? linuxSshSteps : [], disableIPv6 ? linuxIpv6Steps : [])
var runLinuxGuestConfig = isLinux && !empty(linuxSteps)

resource linuxGuestConfig 'Microsoft.HybridCompute/machines/extensions@2023-10-03-preview' = if (runLinuxGuestConfig) {
  parent: machine
  name: 'CustomScript'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: '/bin/sh -c "${join(linuxSteps, '; ')}"'
    }
  }
  dependsOn: [
    vm
  ]
}

// ---------- Optional: Azure Arc SSH (Windows) ----------
// 'OpenSSH for Windows - Azure Arc' installs and enables sshd so you can connect with az ssh arc
// (no inbound port or public IP needed). Windows Server 2025 already ships OpenSSH; the extension configures it.
resource openSsh 'Microsoft.HybridCompute/machines/extensions@2023-10-03-preview' = if (isWindows && installSshExtension) {
  parent: machine
  name: 'WindowsOpenSSH'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.OpenSSH'
    type: 'WindowsOpenSSH'
    typeHandlerVersion: '3.0.1.0'
    autoUpgradeMinorVersion: true
  }
  dependsOn: [
    vm
    guestConfig
  ]
}

output machineId string = machine.id
output nicId string = nic.id
