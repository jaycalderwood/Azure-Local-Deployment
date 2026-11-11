# azure-local-devops

> **Note:** IDs, names and domains in this repo (subscription, custom location, Key Vault, `contoso.com`, `your-ado-org`) are placeholders. Set your own in `pipelines/vars/azlocal.yml` and `params/*.bicepparam`, then run `scripts/Initialize-AzureLocalDevOps.ps1`.

Self-service Azure Local (azlocal-cluster01) provisioning from Azure DevOps: fill in a form, review the what-if,
approve, done. Windows and Linux VMs, logical networks, NSGs, AVD session hosts and AKS clusters - plus a
Git/PR path for VMs you want defined in code, and a scrubbed public copy published to GitHub.

## The forms (Pipelines > *name* > Run pipeline)

| Pipeline | What it builds | Runs as |
|---|---|---|
| **New VM** | One Arc VM, **Windows or Linux** (the OS follows the image you pick): size, data disk, logical network, auto/pinned IP, optional NSG on the NIC, remote access on (RDP + ping on Windows, SSH on Linux), IPv6 off, domain join (Windows), optional SSH key (Linux), optional Azure Arc SSH extension. Per-VM local admin password in Key Vault (`vm-<name>-admin`). | sc-azlocal-vms |
| **New Logical Network** | Static (IP pool) or DHCP logical network, optional VLAN, DNS, optional NSG for the whole network. | sc-azlocal-infra |
| **New NSG** | Creates/updates an NSG from a rule preset and optionally attaches it to a logical network (refuses to touch a network with VMs on it unless you tick the confirm box). | sc-azlocal-infra |
| **New AVD Hosts** | Host pool + desktop app group + workspace (when new), then N **Windows** session hosts that install the AVD agent, join the domain and register. | sc-azlocal-vms |
| **New AKS Cluster** | AKS enabled by Arc on a Static logical network; checks the pool has control plane + workers + 2 free IPs; node SSH key in Key Vault. | sc-azlocal-infra |
| **Sync Dropdowns** | Refreshes the logical network / NSG / image / host pool dropdowns from Azure and commits to main. Runs every 6 h and at the end of New Logical Network / New NSG / New AVD Hosts. | sc-azlocal-vms |
| AzureLocal-Deploy | Git path: `params/*.bicepparam` on merge to main. | both |
| AzureLocal-PR-Validation | What-if on every PR. | both |
| Publish to GitHub | Scrubbed snapshot of main to the public GitHub repo after every merge (see below). | - |

Every form has a **Preview** stage (validation + what-if, no changes) and a **Deploy** stage gated by the
`azlocal-prod` approval.

### Where the results are

At the end of a New VM / New AVD Hosts run you get the VM's IP, the local admin user, and either the
password (if you ticked **Show the local admin password**) or the Key Vault secret that holds it:

- at the **end of the Deploy log** (a boxed block), and
- on the run page's **Extensions** tab, under the VM / host pool name.

Both are written **even if a later step fails** (for example the domain join) - the VM usually exists by
then, so you can still sign in and look. To copy a password at any time:

```powershell
az keyvault secret show --vault-name kv-azlocal-demo -n vm-<name>-admin --query value -o tsv | Set-Clipboard
```

### Windows vs Linux VMs

| | Windows | Linux |
|---|---|---|
| Chosen by | a Windows image | a Linux image (e.g. Ubuntu) - the form reads the image's OS type |
| Name length | 1-15 characters | 1-54 characters |
| Sign-in | `azladmin` + password (`mstsc /v:<ip>`) | `azladmin` + password, plus your SSH key if you paste one (`ssh azladmin@<ip>`) |
| Remote access box | RDP on, firewall rules + ping opened | SSH enabled and started |
| Turn off IPv6 box | unbind + `DisabledComponents=0xFF` | `sysctl` (`/etc/sysctl.d/99-disable-ipv6.conf`) |
| Domain join | yes (`svc-domainjoin`, `OU=AzureLocal`) | skipped with a warning (use realmd/sssd inside the VM) |
| Secure Boot | on | on for signed images such as Ubuntu; untick only if an unsigned image won't boot |
| Azure Arc SSH box | installs **OpenSSH for Windows - Azure Arc** (`Microsoft.Azure.OpenSSH` / `WindowsOpenSSH` 3.0.1.0) | makes sure `sshd` is enabled (Linux needs no extension) |
| Guest config extension | `CustomScriptExtension` (Microsoft.Compute) | `CustomScript` (Microsoft.Azure.Extensions) |

**Azure Arc SSH** lets you connect through Azure Arc with no network path or open inbound port:

```powershell
az extension add --upgrade --name ssh
az ssh arc --resource-group Infrastructure --name <vm> --local-user azladmin          # add --rdp for RDP over SSH (Windows)
```

The first connection may ask to allow port 22 as the Arc SSH endpoint. Your account needs Azure Stack HCI
Administrator (or higher) on the resource group. On Windows the extensions run in order: guest script ->
OpenSSH -> domain join.

Guest configuration and the domain join are delivered through the Arc agent in the VM ("guest
management"), which the template asks for at creation (`provisionVMAgent: true`). If those steps sit
waiting, check `az stack-hci-vm show --name <vm> --resource-group Infrastructure --query "properties.instanceView.vmAgent"`.

To offer a Linux image in the forms, add it to the cluster (portal: **Azure Local > VM images > Add VM image
> From Azure Marketplace**, or `params/infra.bicepparam` with `osType: 'Linux'`), then run **Sync Dropdowns**.
AVD only accepts Windows images.

### NSG presets (`bicep/modules/nsg.bicep`)

| Preset | Inbound allowed | Notes |
|---|---|---|
| Windows-Server-Baseline | RDP, ping, WinRM from the management CIDR | deny all other inbound, allow outbound |
| Web-Server | baseline + HTTP/HTTPS from anywhere | |
| Domain-Controller | baseline + DNS, Kerberos, LDAP/GC, SMB/RPC, NTP | |
| Allow-Subnet-Only | everything from the management CIDR | good for Linux VMs (includes SSH) |
| Deny-All-Inbound | nothing | outbound allowed |

The Windows baseline does not open SSH (22). For a Linux VM behind an NSG use **Allow-Subnet-Only**.

### Naming rules

Azure rejects names containing `microsoft` or `windows`, starting with `login` or `xbox`, or equal to
reserved words such as `azure` or `office`. Every form checks this in Preview.

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
    vm.bicep               Arc machine, NIC (+NSG, DNS), disks, VM (Windows/Linux), guest config
                           (Windows: RDP/IPv6/AVD agent, Linux: SSH/IPv6), domain join (Windows)
    logicalNetwork.bicep   (+NSG)
    nsg.bicep              NSG + preset rules
    storagePath.bicep, marketplaceImage.bicep
pipelines/
  new-*.yml, sync-dropdowns.yml   the forms
  azure-pipelines.yml, pr-validation.yml
  publish-to-github.yml    scrubbed copy to GitHub
  vars/azlocal.yml         shared values (RG, custom location, Key Vault, domain, OU, DNS ...)
  templates/               preview-and-deploy, run-script, deploy-bicep
publish/
  scrub-map.json           real value -> placeholder map (never published)
scripts/
  pipeline/*.sh            what each form runs on the agent
  azl.py                   resource lookups for the scripts (incl. an image's OS type)
  sync_dropdowns.py        rewrites the AUTO dropdown blocks
  publish/export_public.py scrub + leak check for the GitHub copy
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

## Making changes (Azure DevOps first, GitHub follows)

```powershell
cd C:\Repos\azure-local-devops
git checkout main; git pull origin main; git checkout -b <change-name>
# edit files, or extract an updated zip over the repo:
#   Expand-Archive "$HOME\Downloads\azure-local-devops.zip" -DestinationPath C:\Repos -Force
git add -A; git commit -m "<what changed>"; git push -u origin <change-name>
```

Open a pull request to `main` and complete it. **Publish to GitHub** then pushes the scrubbed copy to
GitHub automatically. Never edit on GitHub directly - the next publish overwrites it.

## Publish to GitHub

`pipelines/publish-to-github.yml` scrubs real IDs, names and domains using `publish/scrub-map.json`, runs a
leak check (unknown GUIDs, tokens, keys), attaches the scrubbed copy as the **public-preview** artifact, and
pushes a snapshot - not the Azure Repos history. Needs the `github-publish` variable group with
`GITHUB_TOKEN` (fine-grained PAT, Contents read/write on the GitHub repo). Add new identifying values to
the scrub map.

## Day-2

- **Delete a VM**: `az stack-hci-vm delete --resource-group Infrastructure --name <vm> --yes`
  (then `az keyvault secret delete --vault-name kv-azlocal-demo -n vm-<name>-admin` if you like).
- **After a VM exists** its NIC settings (IP, DNS, network, NSG) can't change - only CPU, memory, disks.
- **Dropdown missing something?** Run **Sync Dropdowns**.
- **Change shared values** (domain, OU, DNS, Key Vault): `pipelines/vars/azlocal.yml`.
