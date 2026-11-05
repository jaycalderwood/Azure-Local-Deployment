// Azure Local network security group (SDN enabled by Arc) with a named rule preset.
// Re-deploying adds/updates the preset's rules; rules not in the preset are left alone.
metadata description = 'Creates or updates an Azure Local NSG with a preset rule set.'

@description('NSG name')
param name string

param location string

@description('Full resource ID of the Azure Local custom location')
param customLocationId string

@allowed([
  'Windows-Server-Baseline'
  'Web-Server'
  'Domain-Controller'
  'Allow-Subnet-Only'
  'Deny-All-Inbound'
  'None'
])
@description('Which preset rules to apply. None = create/keep the NSG without touching rules.')
param ruleSet string = 'Windows-Server-Baseline'

@description('Where admin traffic (RDP, WinRM, ping) is allowed from, e.g. 10.1.10.0/24')
param managementCidr string = '10.1.10.0/24'

param tags object = {}

var extendedLocation = {
  type: 'CustomLocation'
  name: customLocationId
}

// Rule helper fields: n=name p=priority d=direction a=access proto=protocol src=sources ports=destination ports
var mgmtRules = [
  { n: 'Allow-RDP-Mgmt', p: 100, d: 'Inbound', a: 'Allow', proto: 'Tcp', src: [managementCidr], ports: ['3389'], desc: 'RDP from management network' }
  { n: 'Allow-ICMP-Mgmt', p: 110, d: 'Inbound', a: 'Allow', proto: 'Icmp', src: [managementCidr], ports: ['*'], desc: 'Ping from management network' }
  { n: 'Allow-WinRM-Mgmt', p: 120, d: 'Inbound', a: 'Allow', proto: 'Tcp', src: [managementCidr], ports: ['5985-5986'], desc: 'PowerShell remoting from management network' }
]
var webRules = [
  { n: 'Allow-HTTP', p: 200, d: 'Inbound', a: 'Allow', proto: 'Tcp', src: ['*'], ports: ['80'], desc: 'HTTP from anywhere' }
  { n: 'Allow-HTTPS', p: 210, d: 'Inbound', a: 'Allow', proto: 'Tcp', src: ['*'], ports: ['443'], desc: 'HTTPS from anywhere' }
]
var dcRules = [
  { n: 'Allow-DNS-TCP', p: 300, d: 'Inbound', a: 'Allow', proto: 'Tcp', src: ['*'], ports: ['53'], desc: 'DNS' }
  { n: 'Allow-DNS-UDP', p: 301, d: 'Inbound', a: 'Allow', proto: 'Udp', src: ['*'], ports: ['53'], desc: 'DNS' }
  { n: 'Allow-Kerberos-TCP', p: 310, d: 'Inbound', a: 'Allow', proto: 'Tcp', src: ['*'], ports: ['88', '464'], desc: 'Kerberos + kpasswd' }
  { n: 'Allow-Kerberos-UDP', p: 311, d: 'Inbound', a: 'Allow', proto: 'Udp', src: ['*'], ports: ['88', '464'], desc: 'Kerberos + kpasswd' }
  { n: 'Allow-LDAP-TCP', p: 320, d: 'Inbound', a: 'Allow', proto: 'Tcp', src: ['*'], ports: ['389', '636', '3268-3269'], desc: 'LDAP, LDAPS, Global Catalog' }
  { n: 'Allow-LDAP-UDP', p: 321, d: 'Inbound', a: 'Allow', proto: 'Udp', src: ['*'], ports: ['389'], desc: 'LDAP (UDP)' }
  { n: 'Allow-SMB-RPC', p: 330, d: 'Inbound', a: 'Allow', proto: 'Tcp', src: ['*'], ports: ['135', '445', '49152-65535'], desc: 'SMB, RPC endpoint mapper + dynamic RPC' }
  { n: 'Allow-NTP', p: 340, d: 'Inbound', a: 'Allow', proto: 'Udp', src: ['*'], ports: ['123'], desc: 'Time sync' }
]
var subnetRules = [
  { n: 'Allow-All-From-Mgmt', p: 100, d: 'Inbound', a: 'Allow', proto: '*', src: [managementCidr], ports: ['*'], desc: 'Everything from the management network' }
]
var closingRules = [
  { n: 'Allow-All-Outbound', p: 4000, d: 'Outbound', a: 'Allow', proto: '*', src: ['*'], ports: ['*'], desc: 'Outbound traffic allowed' }
  { n: 'Deny-All-Inbound', p: 4096, d: 'Inbound', a: 'Deny', proto: '*', src: ['*'], ports: ['*'], desc: 'Anything not allowed above is blocked' }
]

var presets = {
  'Windows-Server-Baseline': concat(mgmtRules, closingRules)
  'Web-Server': concat(mgmtRules, webRules, closingRules)
  'Domain-Controller': concat(mgmtRules, dcRules, closingRules)
  'Allow-Subnet-Only': concat(subnetRules, closingRules)
  'Deny-All-Inbound': closingRules
  None: []
}
var rules = presets[ruleSet]

resource nsg 'Microsoft.AzureStackHCI/networkSecurityGroups@2025-06-01-preview' = {
  name: name
  location: location
  tags: tags
  extendedLocation: extendedLocation
  properties: {}
}

@batchSize(1) // NSG rule writes are serialized by the network controller
resource nsgRules 'Microsoft.AzureStackHCI/networkSecurityGroups/securityRules@2025-06-01-preview' = [
  for r in rules: {
    parent: nsg
    name: r.n
    extendedLocation: extendedLocation
    properties: {
      description: r.desc
      priority: r.p
      direction: r.d
      access: r.a
      protocol: r.proto
      sourceAddressPrefixes: r.src
      sourcePortRanges: ['*']
      destinationAddressPrefixes: ['*']
      destinationPortRanges: r.ports
    }
  }
]

output id string = nsg.id
output ruleNames array = [for r in rules: r.n]
