#Requires -Version 7.0
<#
.SYNOPSIS
  Adds the form pipelines (New VM, New Logical Network, New NSG, New AVD Hosts, New AKS Cluster,
  Sync Dropdowns) to Azure DevOps and grants the extra Azure permissions they need.
  Run it after the pipelines/*.yml files are merged into main. Safe to re-run.

.DESCRIPTION
  AZURE
    - Registers resource providers for AVD and AKS
    - VM identity  (sc-azlocal-vms):   Key Vault Secrets Officer, Desktop Virtualization Contributor,
                                       and NSG join rights if the VM Contributor role lacks them
    - Infra identity (sc-azlocal-infra): Contributor on the cluster RG (AKS needs it), Key Vault Secrets Officer
  AZURE DEVOPS
    - Creates/renames the six pipelines, pre-authorizes them for the service connections,
      variable group and environment
    - Lets the build service push the dropdown updates to main (Contribute + Bypass policies)
    - Queues Sync Dropdowns once

.EXAMPLE
  $pat = Read-Host "Paste PAT" -MaskInput
  ./scripts/Add-AzureLocalPipelines.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -AdoPat $pat
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $ResourceGroup      = 'Infrastructure',
    [string] $MgmtResourceGroup  = 'rg-azlocal-devops',
    [string] $KeyVaultName       = 'kv-azlocal-demo',
    [string] $InfraIdentityName  = 'id-azlocal-infra',
    [string] $VmIdentityName     = 'id-azlocal-vms',
    [string] $AdoOrganization    = 'your-ado-org',
    [string] $AdoProject         = 'AzureLocal',
    [string] $AdoRepoName        = 'azure-local-devops',
    [string] $AdoPat,
    [switch] $SkipAzureRoles,
    [switch] $SkipDevOps,
    [switch] $NoInitialSync
)

$ErrorActionPreference = 'Stop'
$env:AZURE_CORE_DISABLE_CONFIRM_PROMPT   = 'true'
$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'yes_without_prompt'
$env:AZURE_CORE_CHECK_FOR_UPDATES        = 'false'
$env:AZURE_CORE_SURVEY_MESSAGE           = 'false'

# Pipeline name -> YAML path. Order matters: Sync Dropdowns references the three before it by name.
$Pipelines = [ordered]@{
    'New VM'              = '/pipelines/new-vm.yml'
    'New Logical Network' = '/pipelines/new-lnet.yml'
    'New NSG'             = '/pipelines/new-nsg.yml'
    'New AVD Hosts'       = '/pipelines/new-avd.yml'
    'New AKS Cluster'     = '/pipelines/new-aks.yml'
    'Sync Dropdowns'      = '/pipelines/sync-dropdowns.yml'
}
$ServiceConnections = 'sc-azlocal-infra', 'sc-azlocal-vms'
$VarGroupName = 'azlocal-secrets'
$EnvName      = 'azlocal-prod'

# ---------------------------------------------------------------------------------------- helpers
$script:StepNo = 0
function Step([string]$t) { $script:StepNo++; Write-Host "`n[$($script:StepNo)] $t" -ForegroundColor Cyan }
function Ok([string]$t)   { Write-Host "    + $t" -ForegroundColor Green }
function Info([string]$t) { Write-Host "    - $t" }
function Warn([string]$t) { Write-Host "    ! $t" -ForegroundColor Yellow }

# Real az executable (the helper is called 'Az'; PowerShell names are case-insensitive)
$script:AzExe = (Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $script:AzExe) { throw 'Azure CLI (az) not found. Open a new PowerShell window after installing it.' }

function Az {
    # Non-advanced on purpose so -o/-n/-g pass straight through. -Raw = text, -AllowFail = $null on error.
    $Raw = $args -contains '-Raw'; $AllowFail = $args -contains '-AllowFail'
    $AzArgs = @($args | Where-Object { $_ -notin '-Raw', '-AllowFail' } | ForEach-Object { "$_" })
    $ErrorActionPreference = 'Continue'
    $out = & $script:AzExe @AzArgs --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) { if ($AllowFail) { return $null }; throw "az $($AzArgs -join ' ') failed:`n$out" }
    $text = ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    if ($Raw -or -not $text) { return "$text".Trim() }
    try { $text | ConvertFrom-Json -Depth 50 } catch { "$text".Trim() }
}

function Grant-Role([string]$PrincipalId, [string]$Role, [string]$Scope) {
    # Filter in PowerShell - JMESPath filters with ( ) [ ] = break az.cmd on Windows
    $have = @(Az role assignment list --role $Role --scope $Scope -o json) | Where-Object { $_.principalId -eq $PrincipalId }
    if ($have) { Info "'$Role' already on $(Split-Path $Scope -Leaf)"; return }
    for ($i = 1; $i -le 6; $i++) {
        try {
            Az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type ServicePrincipal `
                --role $Role --scope $Scope -o none | Out-Null
            Ok "'$Role' -> $(Split-Path $Scope -Leaf)"; return
        } catch { if ($i -eq 6) { throw }; Start-Sleep 15 }
    }
}

function Get-AdoHeaders {
    if ($AdoPat) { return @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")) } }
    if (-not $script:AdoToken) {
        $script:AdoToken = Az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv -Raw
    }
    @{ Authorization = "Bearer $($script:AdoToken)" }
}

function Ado([string]$Method, [string]$Url, $Body = $null, [switch]$AllowNotFound) {
    $req = @{ Method = $Method; Uri = $Url; Headers = (Get-AdoHeaders); ContentType = 'application/json' }
    if ($null -ne $Body) { $req.Body = ($Body | ConvertTo-Json -Depth 40 -Compress) }
    try {
        $r = Invoke-RestMethod @req
        if ($r -is [string] -and $r -match '<html|<!DOCTYPE|Sign In') { throw [System.InvalidOperationException]::new('AUTH203') }
        $r
    } catch [System.InvalidOperationException] {
        if ($_.Exception.Message -ne 'AUTH203') { throw }
        throw "Azure DevOps returned a sign-in page for $Method $Url. Use -AdoPat with a Full access PAT for '$AdoOrganization'."
    } catch {
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        if ($AllowNotFound -and $code -eq 404) { return $null }
        $detail = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        $detail = ($detail -replace '(?s)<style.*?</style>' -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
        if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) + '...' }
        throw "Azure DevOps $Method $Url failed ($code): $detail"
    }
}

# ------------------------------------------------------------------------------------------ Azure
Az account set --subscription $SubscriptionId | Out-Null
$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"

if (-not $SkipAzureRoles) {
    Step 'Resource providers for AVD and AKS'
    foreach ($ns in 'Microsoft.DesktopVirtualization', 'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration',
                    'Microsoft.HybridContainerService', 'Microsoft.ExtendedLocation') {
        $state = Az provider show -n $ns --query registrationState -o tsv -Raw
        if ($state -ne 'Registered') { Info "Registering $ns"; Az provider register -n $ns --wait | Out-Null }
        Ok "$ns registered"
    }

    Step 'Roles for the pipeline identities'
    $vmId    = Az identity show -g $MgmtResourceGroup -n $VmIdentityName
    $infraId = Az identity show -g $MgmtResourceGroup -n $InfraIdentityName
    $kvId    = Az keyvault show -n $KeyVaultName --query id -o tsv -Raw

    Info "$VmIdentityName (New VM, New AVD Hosts, Sync Dropdowns)"
    Grant-Role $vmId.principalId 'Key Vault Secrets Officer' $kvId
    Grant-Role $vmId.principalId 'Desktop Virtualization Contributor' $rgScope

    # Attaching an NSG to a NIC needs NSG read/join rights; older VM Contributor definitions lack them.
    $def = @(Az role definition list --name 'Azure Stack HCI VM Contributor' -o json)[0]
    $actions = @($def.permissions | ForEach-Object { $_.actions }) | Where-Object { $_ }
    $nsgOk = $actions | Where-Object { $_ -match '^(\*|Microsoft\.AzureStackHCI/(\*|networkSecurityGroups/))' }
    if ($nsgOk) { Info "Azure Stack HCI VM Contributor already covers NSGs" }
    else {
        Warn "Azure Stack HCI VM Contributor has no NSG permissions - giving $VmIdentityName Azure Stack HCI Administrator on $ResourceGroup"
        Grant-Role $vmId.principalId 'Azure Stack HCI Administrator' $rgScope
    }

    Info "$InfraIdentityName (New Logical Network, New NSG, New AKS Cluster)"
    Grant-Role $infraId.principalId 'Contributor' $rgScope            # AKS Arc requires Contributor
    Grant-Role $infraId.principalId 'Key Vault Secrets Officer' $kvId # AKS node SSH key
}

if ($SkipDevOps) { Write-Host "`nAzure part done (-SkipDevOps)." -ForegroundColor Green; return }

# ----------------------------------------------------------------------------------- Azure DevOps
$Org = "https://dev.azure.com/$AdoOrganization"
$ProjUrl = "$Org/$([uri]::EscapeDataString($AdoProject))"
$api = 'api-version=7.1'

Step "Azure DevOps project, repo and shared resources"
$proj = Ado GET "$Org/_apis/projects/$([uri]::EscapeDataString($AdoProject))?$api"
$repo = Ado GET "$ProjUrl/_apis/git/repositories/${AdoRepoName}?$api"
Ok "Project $AdoProject, repo $AdoRepoName"

$missing = foreach ($path in $Pipelines.Values) {
    $item = Ado GET "$ProjUrl/_apis/git/repositories/$($repo.id)/items?path=$([uri]::EscapeDataString($path))&versionDescriptor.version=main&$api" -AllowNotFound
    if (-not $item) { $path }
}
if ($missing) { throw "These files aren't on main yet - merge the pull request first: $($missing -join ', ')" }
Ok 'All pipeline YAML files are on main'

$endpointIds = foreach ($n in $ServiceConnections) {
    $ep = (Ado GET "$ProjUrl/_apis/serviceendpoint/endpoints?endpointNames=$n&$api").value | Select-Object -First 1
    if (-not $ep) { throw "Service connection $n not found - run Initialize-AzureLocalDevOps.ps1 first." }
    $ep.id
}
$vg = (Ado GET "$ProjUrl/_apis/distributedtask/variablegroups?groupName=$VarGroupName&$api").value | Select-Object -First 1
$adoEnv = (Ado GET "$ProjUrl/_apis/pipelines/environments?name=$EnvName&$api").value | Select-Object -First 1
if (-not $vg -or -not $adoEnv) { throw "Variable group $VarGroupName or environment $EnvName missing - run Initialize-AzureLocalDevOps.ps1 first." }
Ok "Service connections, variable group $($vg.id), environment $($adoEnv.id)"

Step 'Pipelines'
$defs = @((Ado GET "$ProjUrl/_apis/build/definitions?includeAllProperties=true&$api").value)
$pipelineIds = [ordered]@{}
foreach ($name in $Pipelines.Keys) {
    $path = $Pipelines[$name]
    $byName = $defs | Where-Object { $_.name -eq $name } | Select-Object -First 1
    $byPath = $defs | Where-Object { $_.repository.id -eq $repo.id -and ('/' + "$($_.process.yamlFilename)".TrimStart('/')) -eq $path } | Select-Object -First 1
    if ($byName) {
        Info "$name exists ($($byName.id))"; $pipelineIds[$name] = $byName.id
    } elseif ($byPath) {
        $full = Ado GET "$ProjUrl/_apis/build/definitions/$($byPath.id)?$api"
        Info "Renaming '$($full.name)' -> '$name'"
        $full.name = $name
        Ado PUT "$ProjUrl/_apis/build/definitions/$($byPath.id)?$api" $full | Out-Null
        Ok "$name ($($byPath.id))"; $pipelineIds[$name] = $byPath.id
    } else {
        $created = Ado POST "$ProjUrl/_apis/pipelines?$api" @{
            name = $name; folder = '\'
            configuration = @{ type = 'yaml'; path = $path; repository = @{ id = $repo.id; name = $AdoRepoName; type = 'azureReposGit' } }
        }
        Ok "$name created ($($created.id))"; $pipelineIds[$name] = $created.id
    }
}

Step 'Pre-authorize pipelines (no "Permit" prompts on first run)'
$grant = @{ pipelines = @($pipelineIds.Values | ForEach-Object { @{ id = $_; authorized = $true } }) }
$resources = @($endpointIds | ForEach-Object { , @('endpoint', $_) }) + , @('variablegroup', $vg.id) + , @('environment', $adoEnv.id)
foreach ($r in $resources) {
    Ado PATCH "$ProjUrl/_apis/pipelines/pipelinePermissions/$($r[0])/$($r[1])?api-version=7.1-preview.1" $grant | Out-Null
}
Ok "Authorized $($pipelineIds.Count) pipelines for $($resources.Count) resources"

Step 'Let Sync Dropdowns push to main (Contribute + Bypass policies when pushing)'
try {
    $gitNamespace = '2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87'
    $token = "repoV2/$($proj.id)/$($repo.id)"
    $allow = 4 + 128   # GenericContribute + PolicyExempt
    foreach ($who in "$AdoProject Build Service ($AdoOrganization)", "Project Collection Build Service ($AdoOrganization)") {
        $ident = (Ado GET "https://vssps.dev.azure.com/$AdoOrganization/_apis/identities?searchFilter=General&filterValue=$([uri]::EscapeDataString($who))&queryMembership=None&$api").value |
            Select-Object -First 1
        if (-not $ident) { Warn "Identity '$who' not found - skipped"; continue }
        Ado POST "$Org/_apis/accesscontrolentries/${gitNamespace}?$api" @{
            token = $token; merge = $true
            accessControlEntries = @(@{ descriptor = $ident.descriptor; allow = $allow; deny = 0; extendedInfo = @{} })
        } | Out-Null
        Ok $who
    }
} catch {
    Warn "Couldn't set repo permissions automatically: $($_.Exception.Message)"
    Warn "Do it by hand: Project settings > Repositories > $AdoRepoName > Security > '$AdoProject Build Service ($AdoOrganization)'"
    Warn "  set 'Contribute' and 'Bypass policies when pushing' to Allow."
}

if (-not $NoInitialSync) {
    Step 'Queue Sync Dropdowns once'
    try {
        $run = Ado POST "$ProjUrl/_apis/pipelines/$($pipelineIds['Sync Dropdowns'])/runs?$api" @{
            resources = @{ repositories = @{ self = @{ refName = 'refs/heads/main' } } }
        }
        Ok "Run $($run.id) queued: $ProjUrl/_build/results?buildId=$($run.id)"
    } catch { Warn "Couldn't queue it ($($_.Exception.Message)) - run Sync Dropdowns from Pipelines once." }
}

Step 'Done'
foreach ($name in $pipelineIds.Keys) { Write-Host ("    {0,-20} {1}/_build?definitionId={2}" -f $name, $ProjUrl, $pipelineIds[$name]) }
