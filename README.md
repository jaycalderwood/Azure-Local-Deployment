# azure-local-devops

> **Note:** IDs, names and domains in this repo (subscription, custom location, Key Vault, `contoso.com`, `your-ado-org`) are placeholders. Set your own in `pipelines/vars/azlocal.yml` and `params/*.bicepparam`, then run `scripts/Initialize-AzureLocalDevOps.ps1`.

Self-service Azure Local (azlocal-cluster01) provisioning from Azure DevOps: fill in a form, review the what-if,
approve, done. Plus a Git/PR path for VMs you want defined in code.

## The forms (Pipelines > *name* > Run pipeline)

| Pipeline | What it builds | Runs as |
|---|---|---|
| **New VM** | One Arc VM: image, size, data disk, logical network, auto/pinned IP, optional NSG on the NIC, domain join, RDP on, IPv6 off. Per-VM admin password in Key Vault (`vm-<name>-admin`). | sc-azlocal-vms |
| **New Logical Network** | Static (IP pool) or DHCP logical network, optional VLAN, DNS, optional NSG for the whole network. | sc-azlocal-infra |
| **New NSG** | Creates/updates an NSG from a rule preset and optionally attaches it to a logical network (refuses to touch a network with VMs on it unless you tick the confirm box). | sc-azlocal-infra |
| **New AVD Hosts** | Host pool + desktop app group + workspace (when new), then N session hosts that install the AVD agent, join the domain and register. | sc-azlocal-vms |
| **New AKS Cluster** | AKS enabled by Arc on a Static logical network; checks the pool has control plane + workers + 2 free IPs; node SSH key in Key Vault. | sc-azlocal-infra |
| **Sync Dropdowns** | Refreshes the logical network / NSG / image / host pool dropdowns from Azure and commits to main. Runs every 6 h and after the three forms that create those things. | sc-azlocal-vms |
| AzureLocal-Deploy | Git path: `params/*.bicepparam` on merge to main. | both |
| AzureLocal-PR-Validation | What-if on every PR. | both |

Every form has a **Preview** stage (validation + what-if, no changes) and a **Deploy** stage gated by the
`azlocal-prod` approval.

### NSG presets (`bicep/modules/nsg.bicep`)

| Preset | Inbound allowed | Notes |
|---|---|---|
| Windows-Server-Baseline | RDP, ping, WinRM from the management CIDR | deny all other inbound, allow outbound |
| Web-Server | baseline + HTTP/HTTPS from anywhere | |
| Domain-Controller | baseline + DNS, Kerberos, LDAP/GC, SMB/RPC, NTP | |
| Allow-Subnet-Only | everything from the management CIDR | |
| Deny-All-Inbound | nothing | outbound allowed |

### SDN

SDN enabled by Arc is switched on once per cluster on a node (`Add-EceFeature`); it isn't an ARM
deployment, so there's no pipeline for it. It's already on here (NSGs exist). The SDN features you manage
day to day - logical networks, NSGs and rules, NSG on a network or a NIC - are the forms above.

## Layout

```
bicep/
  single-vm.bicep          New VM form
  avd-hostpool.bicep       AVD host pool + app group + workspace
  avd-hosts.bicep          AVD session hosts
  infra.bicep / vms.bicep  Git path (params/*.bicepparam)
  modules/
    vm.bicep               Arc machine, NIC (+NSG, DNS), disks, VM, guest config (RDP/IPv6/AVD agent), domain join
    logicalNetwork.bicep   (+NSG)
    nsg.bicep              NSG + preset rules
    storagePath.bicep, marketplaceImage.bicep
pipelines/
  new-*.yml, sync-dropdowns.yml   the forms
  azure-pipelines.yml, pr-validation.yml
  vars/azlocal.yml         shared values (RG, custom location, Key Vault, domain, OU, DNS ...)
  templates/               preview-and-deploy, run-script, deploy-bicep
scripts/
  pipeline/*.sh            what each form runs on the agent
  azl.py                   resource lookups for the scripts
  sync_dropdowns.py        rewrites the AUTO dropdown blocks
  Initialize-AzureLocalDevOps.ps1   one-time setup (identities, Key Vault, DevOps project)
  Add-AzureLocalPipelines.ps1       registers the forms + extra roles + build-service push rights
```

## Setup

```powershell
# 1. one time: identities, Key Vault, service connections, main pipelines
./scripts/Initialize-AzureLocalDevOps.ps1 -SubscriptionId <sub> -AdoOrganization your-ado-org -AdoPat $pat

# 2. after the pipelines/*.yml files are merged to main: register the forms
./scripts/Add-AzureLocalPipelines.ps1 -SubscriptionId <sub> -AdoPat $pat
```

Both are safe to re-run.

## Day-2

- **Delete a VM**: `az stack-hci-vm delete --resource-group Infrastructure --name <vm> --yes`
  (then `az keyvault secret delete --vault-name kv-azlocal-demo -n vm-<name>-admin` if you like).
- **Dropdown missing something?** Run **Sync Dropdowns**.
- **Change shared values** (domain, OU, DNS, Key Vault): `pipelines/vars/azlocal.yml`.
