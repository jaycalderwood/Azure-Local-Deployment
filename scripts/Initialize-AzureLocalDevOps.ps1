#Requires -Version 7.0
<#
.SYNOPSIS
  One-shot, re-runnable setup of everything Azure DevOps needs to deploy to Azure Local.

.DESCRIPTION
  AZURE SIDE (always)
    1. Checks login, subscription, resource providers, Arc Resource Bridge health
    2. Discovers region + custom location from the cluster resource group
    3. Creates the management RG (and VM RG if separate)
    4. Creates two user-assigned managed identities (infra + vms)
    5. Assigns least-privilege Azure Local roles
    6. Creates an RBAC-mode Key Vault and stores vmAdminPassword / domainJoinPassword
    7. Writes discovered values into params/*.bicepparam and pipelines/*.yml

  AZURE DEVOPS SIDE (unless -SkipDevOps)
    8. Creates/finds the project and Git repo, pushes this repo
    9. Creates two Azure RM service connections (workload identity federation, managed identity)
       and adds the matching federated credential to each identity
   10. Creates the Key Vault-linked variable group 'azlocal-secrets'
   11. Creates environment 'azlocal-prod' with you as approver
   12. Creates the deploy + PR-validation pipelines, pre-authorizes them,
       and adds the PR build-validation policy on main

  Safe to re-run: every step checks for existing resources first.

.PARAMETER AdoOrganization
  Organization name only, e.g. 'your-ado-org' for https://dev.azure.com/your-ado-org

.PARAMETER AdoPat
  Optional PAT (Full access, or: Project & Team RW, Code RW, Build RW, Service Connections RW,
  Variable Groups RW, Environment RW, Policy RW). Without it, your az login token is used, which
  works when the DevOps org is backed by the same Entra tenant.

.EXAMPLE
  # Azure only
  ./Initialize-AzureLocalDevOps.ps1 -SubscriptionId <sub> -SkipDevOps

.EXAMPLE
  # Everything
  ./Initialize-AzureLocalDevOps.ps1 -SubscriptionId <sub> -AdoOrganization your-ado-org -GenerateVmAdminPassword
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,

    # ---- Azure ----
    [string] $ClusterResourceGroup = 'Infrastructure',
    [string] $VmResourceGroup      = '',                 # empty = same as cluster RG
    [string] $MgmtResourceGroup    = 'rg-azlocal-devops',
    [string] $KeyVaultName         = '',                 # empty = kv-azl-<8 chars of sub id>
    [string] $InfraIdentityName    = 'id-azlocal-infra',
    [string] $VmIdentityName       = 'id-azlocal-vms',
    [switch] $GenerateVmAdminPassword,
    [switch] $SkipDomainJoinSecret,                      # store a placeholder; set the real one later
    [switch] $RotateSecrets,
    [switch] $AddArcExtensionRole,

    # ---- Azure DevOps ----
    [switch] $SkipDevOps,
    [string] $AdoOrganization,
    [string] $AdoProject      = 'AzureLocal',
    [string] $AdoRepoName     = 'azure-local-devops',
    [string] $AdoPat,
    [string] $RepoPath        = (Split-Path $PSScriptRoot -Parent),
    [switch] $SkipPush
)

$ErrorActionPreference = 'Stop'

# az output is captured by this script, so any interactive prompt would hang invisibly. Turn them off.
$env:AZURE_CORE_DISABLE_CONFIRM_PROMPT       = 'true'
$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL     = 'yes_without_prompt'
$env:AZURE_CORE_COLLECT_TELEMETRY            = 'false'
$env:AZURE_CORE_SURVEY_MESSAGE               = 'false'
$env:AZURE_CORE_CHECK_FOR_UPDATES            = 'false'

# Names the repo's pipelines expect
$ScInfra      = 'sc-azlocal-infra'
$ScVms        = 'sc-azlocal-vms'
$VarGroupName = 'azlocal-secrets'
$EnvName      = 'azlocal-prod'
$PipeDeploy   = 'AzureLocal-Deploy'
$PipePr       = 'AzureLocal-PR-Validation'
$AdoResource  = '499b84ac-1321-427f-aa17-267ca6975798'   # Azure DevOps Entra resource ID

if (-not $VmResourceGroup) { $VmResourceGroup = $ClusterResourceGroup }
if (-not $KeyVaultName)    { $KeyVaultName = 'kv-azl-' + $SubscriptionId.Replace('-', '').Substring(0, 8) }
if (-not $SkipDevOps -and -not $AdoOrganization) {
    throw 'Pass -AdoOrganization <name>, or -SkipDevOps to do only the Azure side.'
}

# =============================================================================
# Helpers
# =============================================================================
$script:StepNo = 0
function Step([string]$Text) { $script:StepNo++; Write-Host "`n[$script:StepNo] $Text" -ForegroundColor Cyan }
function Ok([string]$Text)   { Write-Host "    + $Text" -ForegroundColor Green }
function Info([string]$Text) { Write-Host "    - $Text" }
function Warn([string]$Text) { Write-Host "    ! $Text" -ForegroundColor Yellow }

# Resolve the real Azure CLI executable. The helper below is named 'Az', and PowerShell names are
# case-insensitive, so a bare 'az' inside it would call the helper itself (infinite recursion).
$script:AzExe = (Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $script:AzExe) { throw 'Azure CLI (az) not found on PATH. Open a new PowerShell window after installing it.' }

function Az {
    # Simple (non-advanced) function on purpose: passes -o/-n/-g straight through to az.
    # Runs az, throws on failure, returns parsed JSON (or trimmed text with -Raw). -AllowFail returns $null.
    $Raw       = $args -contains '-Raw'
    $AllowFail = $args -contains '-AllowFail'
    $AzArgs    = @($args | Where-Object { $_ -notin '-Raw', '-AllowFail' } | ForEach-Object { "$_" })
    $ErrorActionPreference = 'Continue'
    $out = & $script:AzExe @AzArgs --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFail) { return $null }
        throw "az $($AzArgs -join ' ') failed:`n$out"
    }
    $text = ($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    if ($Raw -or -not $text) { return $text.Trim() }
    try { return $text | ConvertFrom-Json -Depth 50 } catch { return $text.Trim() }
}

function Retry([scriptblock]$Action, [string]$What, [int]$Tries = 8, [int]$DelaySec = 15) {
    for ($i = 1; $i -le $Tries; $i++) {
        try { return & $Action }
        catch {
            if ($i -eq $Tries) { throw }
            Info "$What not ready yet (attempt $i/$Tries) - waiting ${DelaySec}s for Entra/RBAC propagation"
            Start-Sleep -Seconds $DelaySec
        }
    }
}

function Grant-Role([string]$PrincipalId, [string]$Role, [string]$Scope, [string]$Type = 'ServicePrincipal') {
    # Filter by principalId in PowerShell (not --assignee, which does a Graph lookup that fails for brand-new
    # identities; and not a JMESPath filter, whose ( ) [ ] = characters break az.cmd on Windows)
    $existing = @(Az role assignment list --role $Role --scope $Scope -o json) | Where-Object { $_.principalId -eq $PrincipalId }
    if ($existing) { Info "'$Role' already on $(Split-Path $Scope -Leaf)"; return }
    Retry -What "Role '$Role'" -Action {
        Az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type $Type `
            --role $Role --scope $Scope -o none | Out-Null
    }
    Ok "'$Role' -> $(Split-Path $Scope -Leaf)"
}

function New-StrongPassword([int]$Length = 24) {
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!@#%^*-_=+')
    $all  = -join $sets
    $chars = foreach ($s in $sets) { $s[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($s.Length)] }
    $chars += 1..($Length - $sets.Count) | ForEach-Object { $all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)] }
    -join ($chars | Sort-Object { [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(1000) })
}

function Set-KvSecret([string]$Vault, [string]$Name, [string]$Value) {
    # Value goes through a temp file so it never appears on a command line
    $tmp = New-TemporaryFile
    try {
        [IO.File]::WriteAllText($tmp.FullName, $Value)
        Retry -What "Key Vault write" -Action {
            Az keyvault secret set --vault-name $Vault --name $Name --file $tmp.FullName --encoding utf-8 -o none | Out-Null
        }
    } finally { Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue }
}

# ---- Azure DevOps REST ----
$script:AdoToken = $null
function Get-AdoHeaders {
    if ($AdoPat) {
        return @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat")) }
    }
    if (-not $script:AdoToken) {
        $script:AdoToken = Az account get-access-token --resource $AdoResource --query accessToken -o tsv -Raw
    }
    @{ Authorization = "Bearer $script:AdoToken" }
}

function Ado([string]$Method, [string]$Url, $Body = $null, [switch]$AllowNotFound) {
    $p = @{ Method = $Method; Uri = $Url; Headers = (Get-AdoHeaders); ContentType = 'application/json' }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 30 -Compress) }
    try {
        $r = Invoke-RestMethod @p
        # Azure DevOps answers unauthorized calls with HTTP 203 + an HTML sign-in page, which
        # Invoke-RestMethod treats as success. Catch that instead of carrying on with a string.
        if ($r -is [string] -and $r -match '<html|<!DOCTYPE|Sign In') {
            throw [System.InvalidOperationException]::new('AUTH203')
        }
        $r
    }
    catch [System.InvalidOperationException] {
        if ($_.Exception.Message -ne 'AUTH203') { throw }
        $how = if ($AdoPat) { 'The PAT was rejected or lacks scope - create a new one with Full access for this organization.' }
               else { 'Your az login token was not accepted - re-run with -AdoPat <token>.' }
        throw "Azure DevOps returned a sign-in page for $Method $Url (not authorized). $how"
    }
    catch {
        $code   = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        if ($AllowNotFound -and $code -eq 404) { return $null }
        $detail = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        # Azure DevOps often returns an HTML error page - keep only the readable first part
        $detail = (($detail -replace '(?s)<style.*?</style>|html \{.*?\}\s*(?=\S)', '' -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim() -split '(?<=\.)\s')[0..1] -join ' '
        if ($detail -match 'materialized|not authorized|401') {
            $detail += "`n  Hint: sign in once at https://aex.dev.azure.com/me with this account and make sure it is a member" +
                       " of the organization (Organization settings > Users), or re-run with -AdoPat <token>."
        }
        throw "Azure DevOps $Method $Url failed ($code): $detail"
    }
}

# =============================================================================
# AZURE SIDE
# =============================================================================
Step 'Azure CLI and subscription'
Info 'Checking az (first run after install can take ~30s)'
$ver = (Az version).'azure-cli'
Info "Azure CLI $ver"
if ([version]$ver -lt [version]'2.60.0') { Warn 'Azure CLI 2.60+ recommended: az upgrade' }
if (-not (Az account show --query id -o tsv -Raw -AllowFail)) {
    throw "Not signed in to Azure CLI. Run 'az login' in this window, pick your subscription, then re-run this script."
}
Az account set --subscription $SubscriptionId | Out-Null
$acct     = Az account show
$TenantId = $acct.tenantId
$SubName  = $acct.name
$Me       = Az ad signed-in-user show --query id -o tsv -Raw -AllowFail
Ok "Subscription: $SubName ($SubscriptionId), tenant $TenantId"
if (-not $Me) { Warn 'Signed in as a service principal - you will need to grant yourself Key Vault access manually.' }

Step 'Resource providers'
foreach ($ns in 'Microsoft.AzureStackHCI', 'Microsoft.HybridCompute', 'Microsoft.ExtendedLocation',
                'Microsoft.ResourceConnector', 'Microsoft.HybridConnectivity', 'Microsoft.KeyVault',
                'Microsoft.ManagedIdentity') {
    $state = Az provider show -n $ns --query registrationState -o tsv -Raw
    if ($state -ne 'Registered') { Info "Registering $ns"; Az provider register -n $ns --wait | Out-Null }
    Ok "$ns registered"
}

Step "Discover Azure Local in $ClusterResourceGroup"
$Location = Az group show -n $ClusterResourceGroup --query location -o tsv -Raw
$cls = @(Az resource list -g $ClusterResourceGroup --resource-type Microsoft.ExtendedLocation/customLocations --query '[].id')
if ($cls.Count -eq 0) { throw "No custom location in $ClusterResourceGroup. Is Azure Local deployed there?" }
if ($cls.Count -gt 1) { Warn "Multiple custom locations; using the first: $($cls[0])" }
$CustomLocationId = $cls[0]
Ok "Region: $Location"
Ok "Custom location: $CustomLocationId"

$bridges = @(Az resource list -g $ClusterResourceGroup --resource-type Microsoft.ResourceConnector/appliances --query '[].id')
foreach ($b in $bridges) {
    $status = Az resource show --ids $b --query properties.status -o tsv -Raw
    if ($status -eq 'Running') { Ok "Arc Resource Bridge $(Split-Path $b -Leaf): Running" }
    else { Warn "Arc Resource Bridge $(Split-Path $b -Leaf) is '$status' - VM deployments will hang until it is Running." }
}
if ($bridges.Count -eq 0) { Warn 'No Arc Resource Bridge found in the cluster RG.' }

foreach ($t in 'storageContainers', 'logicalNetworks', 'marketplaceGalleryImages', 'galleryImages') {
    $names = @(Az resource list -g $ClusterResourceGroup --resource-type "Microsoft.AzureStackHCI/$t" --query '[].name')
    Info ("Existing {0}: {1}" -f $t, ($(if ($names.Count) { $names -join ', ' } else { '(none)' })))
}

Step 'Resource groups'
foreach ($rg in @($MgmtResourceGroup, $VmResourceGroup) | Select-Object -Unique) {
    if ($rg -eq $ClusterResourceGroup) { continue }
    Az group create -n $rg -l $Location --tags managedBy=azure-devops -o none | Out-Null
    Ok "$rg ($Location)"
}

Step 'Managed identities for the service connections'
$idInfra = Az identity create -g $MgmtResourceGroup -n $InfraIdentityName -l $Location
$idVms   = Az identity create -g $MgmtResourceGroup -n $VmIdentityName   -l $Location
Ok "$InfraIdentityName  clientId $($idInfra.clientId)"
Ok "$VmIdentityName    clientId $($idVms.clientId)"

Step 'Role assignments'
$sub          = "/subscriptions/$SubscriptionId"
$clusterScope = "$sub/resourceGroups/$ClusterResourceGroup"
$vmScope      = "$sub/resourceGroups/$VmResourceGroup"

# Infra: logical networks, images, storage paths (VM Contributor cannot create these)
Grant-Role $idInfra.principalId 'Azure Stack HCI Administrator' $clusterScope
# VMs: VM, NIC, disk, extension create/delete
Grant-Role $idVms.principalId 'Azure Stack HCI VM Contributor' $vmScope
if ($VmResourceGroup -ne $ClusterResourceGroup) {
    # Needed to deploy against the custom location and join logical networks/images in the cluster RG
    Grant-Role $idVms.principalId 'Azure Stack HCI VM Contributor' $clusterScope
}
if ($AddArcExtensionRole) {
    Grant-Role $idVms.principalId 'Azure Connected Machine Resource Administrator' $vmScope
}

Step "Key Vault $KeyVaultName"
$kv = Az keyvault show -n $KeyVaultName -AllowFail
if (-not $kv) {
    $deleted = @(Az keyvault list-deleted -o json -AllowFail) | Where-Object { $_.name -eq $KeyVaultName }
    if ($deleted) {
        Info 'Recovering soft-deleted vault'
        Az keyvault recover -n $KeyVaultName -o none | Out-Null
    } else {
        Az keyvault create -n $KeyVaultName -g $MgmtResourceGroup -l $Location `
            --enable-rbac-authorization true --retention-days 90 -o none | Out-Null
    }
    $kv = Az keyvault show -n $KeyVaultName
}
Ok "Vault: $($kv.id)"
if ($Me) { Grant-Role $Me 'Key Vault Secrets Officer' $kv.id 'User' }
Grant-Role $idVms.principalId 'Key Vault Secrets User' $kv.id

function Ensure-Secret([string]$Name, [string]$Prompt, [switch]$Generate, [switch]$Optional) {
    $exists = Az keyvault secret show --vault-name $KeyVaultName -n $Name --query id -o tsv -Raw -AllowFail
    if ($exists -and -not $RotateSecrets) { Info "$Name already set (use -RotateSecrets to change)"; return }
    if ($Generate) {
        $value = New-StrongPassword
        Ok "$Name generated (retrieve: az keyvault secret show --vault-name $KeyVaultName -n $Name --query value -o tsv)"
    } else {
        $sec = Read-Host -AsSecureString $Prompt
        $value = [System.Net.NetworkCredential]::new('', $sec).Password
        if (-not $value) {
            if (-not $Optional) { throw "$Name is required." }
            $value = 'not-used'    # the pipeline maps this variable, so it must exist
            Warn "$Name left empty - stored placeholder; VMs will not be domain joined until you set it"
        }
    }
    Set-KvSecret $KeyVaultName $Name $value
    Ok "$Name stored"
}
Ensure-Secret 'vmAdminPassword'    'Local admin password for new VMs' -Generate:$GenerateVmAdminPassword
if ($SkipDomainJoinSecret) {
    if (-not (Az keyvault secret show --vault-name $KeyVaultName -n domainJoinPassword --query id -o tsv -Raw -AllowFail)) {
        Set-KvSecret $KeyVaultName 'domainJoinPassword' 'not-used'
    }
    Warn "domainJoinPassword placeholder stored. Set it later: az keyvault secret set --vault-name $KeyVaultName -n domainJoinPassword --value '<pw>'"
} else {
    Ensure-Secret 'domainJoinPassword' 'Password of the AD domain-join account (Enter to skip)' -Optional
}

Step 'Write discovered values into the repo'
$bp = Join-Path $RepoPath 'params'
if (Test-Path $bp) {
    foreach ($f in Get-ChildItem $bp -Filter *.bicepparam) {
        $c = Get-Content $f.FullName -Raw
        $c = $c -replace "(?m)^param location = '.*'",          "param location = '$Location'"
        $c = $c -replace "(?m)^param customLocationId = '.*'",  "param customLocationId = '$CustomLocationId'"
        $c = $c -replace "(?m)^param infraResourceGroup = '.*'", "param infraResourceGroup = '$ClusterResourceGroup'"
        Set-Content $f.FullName $c -NoNewline
        Ok "Updated $($f.Name)"
    }
    foreach ($f in Get-ChildItem (Join-Path $RepoPath 'pipelines') -Filter *.yml) {
        $c = Get-Content $f.FullName -Raw
        $c = $c -replace '(?m)(- name: infraResourceGroup\s*\r?\n\s*value: ).*', "`${1}$ClusterResourceGroup"
        $c = $c -replace '(?m)(- name: vmResourceGroup\s*\r?\n\s*value: ).*',    "`${1}$VmResourceGroup"
        Set-Content $f.FullName $c -NoNewline
        Ok "Updated $($f.Name)"
    }
    Warn 'Still edit by hand: vmSwitchName (Get-VMSwitch on a node), image version, IP plan, VM list.'
} else { Warn "No params folder under $RepoPath - skipped." }

# =============================================================================
# AZURE DEVOPS SIDE
# =============================================================================
$summary = [ordered]@{
    SubscriptionId = $SubscriptionId; TenantId = $TenantId; Location = $Location
    CustomLocationId = $CustomLocationId; ClusterResourceGroup = $ClusterResourceGroup
    VmResourceGroup = $VmResourceGroup; KeyVault = $KeyVaultName
    InfraIdentityClientId = $idInfra.clientId; VmIdentityClientId = $idVms.clientId
}

if ($SkipDevOps) {
    Step 'Azure DevOps skipped'
    Info "Create two ARM service connections (Workload identity federation - MANUAL, Managed identity):"
    Info "  $ScInfra -> client ID $($idInfra.clientId)"
    Info "  $ScVms   -> client ID $($idVms.clientId)"
    Info "Then re-run this script with -AdoOrganization to add the federated credentials automatically."
} else {
    $Org = "https://dev.azure.com/$AdoOrganization"
    $api = 'api-version=7.1'

    Step "Azure DevOps project '$AdoProject'"
    $proj = Ado GET "$Org/_apis/projects/$([uri]::EscapeDataString($AdoProject))?$api" -AllowNotFound
    if (-not $proj) {
        $proc = (Ado GET "$Org/_apis/process/processes?$api").value | Where-Object isDefault | Select-Object -First 1
        $op = Ado POST "$Org/_apis/projects?$api" @{
            name = $AdoProject; visibility = 'private'
            capabilities = @{ versioncontrol = @{ sourceControlType = 'Git' }; processTemplate = @{ templateTypeId = $proc.id } }
        }
        do { Start-Sleep 3; $op = Ado GET $op.url } while ($op.status -in 'queued', 'inProgress', 'notSet')
        if ($op.status -ne 'succeeded') { throw "Project creation $($op.status)" }
        $proj = Ado GET "$Org/_apis/projects/$([uri]::EscapeDataString($AdoProject))?$api"
    }
    $ProjId = $proj.id
    if (-not $ProjId) { throw "Azure DevOps did not return an ID for project '$AdoProject'. Response: $($proj | Out-String)" }
    $ProjUrl = "$Org/$([uri]::EscapeDataString($AdoProject))"
    Ok "Project $AdoProject ($ProjId)"

    Step "Git repo '$AdoRepoName'"
    # ${} braces matter: in PowerShell 7 '?' is a legal variable-name character
    $repo = Ado GET "$ProjUrl/_apis/git/repositories/${AdoRepoName}?$api" -AllowNotFound
    if (-not $repo) { $repo = Ado POST "$ProjUrl/_apis/git/repositories?$api" @{ name = $AdoRepoName; project = @{ id = $ProjId } } }
    if (-not $repo.remoteUrl) {
        throw "Could not get the clone URL for repo '$AdoRepoName'. Response: $(($repo | Out-String).Substring(0, [Math]::Min(400, ($repo | Out-String).Length)))"
    }
    Ok $repo.remoteUrl

    if (-not $SkipPush -and (Test-Path (Join-Path $RepoPath 'pipelines/azure-pipelines.yml'))) {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git not found - install it or use -SkipPush.' }
        $auth = (Get-AdoHeaders).Authorization
        Push-Location $RepoPath
        try {
            if (-not (Test-Path .git)) { git init -b main | Out-Null }
            git add -A
            if (git status --porcelain) { git commit -m 'Azure Local IaC: values from Initialize-AzureLocalDevOps' | Out-Null }
            if (git remote | Select-String -SimpleMatch origin) { git remote set-url origin $repo.remoteUrl }
            else { git remote add origin $repo.remoteUrl }
            git -c "http.extraHeader=Authorization: $auth" push -u origin HEAD:main
            if ($LASTEXITCODE -ne 0) { throw 'git push failed' }
            Ok 'Pushed to main'
        } finally { Pop-Location }
    } else { Info 'Push skipped' }

    Step 'Service connections (workload identity federation) + federated credentials'
    function Ensure-ServiceConnection([string]$Name, $Identity) {
        $ep = (Ado GET "$ProjUrl/_apis/serviceendpoint/endpoints?endpointNames=$Name&$api").value | Select-Object -First 1
        if (-not $ep) {
            $ep = Ado POST "$Org/_apis/serviceendpoint/endpoints?$api" @{
                name = $Name; type = 'AzureRM'; url = 'https://management.azure.com/'
                authorization = @{
                    scheme = 'WorkloadIdentityFederation'
                    parameters = @{ tenantid = $TenantId; serviceprincipalid = $Identity.clientId }
                }
                data = @{
                    environment = 'AzureCloud'; scopeLevel = 'Subscription'; creationMode = 'Manual'
                    subscriptionId = $SubscriptionId; subscriptionName = $SubName
                }
                isShared = $false; isReady = $true
                serviceEndpointProjectReferences = @(@{ projectReference = @{ id = $ProjId; name = $AdoProject }; name = $Name })
            }
            Ok "Created $Name"
        } else { Info "$Name exists" }

        $ep = Ado GET "$ProjUrl/_apis/serviceendpoint/endpoints/$($ep.id)?$api"
        $issuer  = $ep.authorization.parameters.workloadIdentityFederationIssuer
        $subject = $ep.authorization.parameters.workloadIdentityFederationSubject
        if (-not $issuer -or -not $subject) { throw "$Name returned no federation issuer/subject." }

        $fcName = "ado-$Name"
        $fc = Az identity federated-credential show -g $MgmtResourceGroup --identity-name $Identity.name -n $fcName -AllowFail
        if ($fc -and $fc.issuer -eq $issuer -and $fc.subject -eq $subject) { Info "Federated credential $fcName ok" }
        else {
            $verb = if ($fc) { 'update' } else { 'create' }
            Az identity federated-credential $verb -g $MgmtResourceGroup --identity-name $Identity.name -n $fcName `
                --issuer $issuer --subject $subject --audiences api://AzureADTokenExchange -o none | Out-Null
            Ok "Federated credential $fcName ($verb)"
        }
        $ep
    }
    $epInfra = Ensure-ServiceConnection $ScInfra $idInfra
    $epVms   = Ensure-ServiceConnection $ScVms   $idVms

    Step "Variable group '$VarGroupName' linked to $KeyVaultName"
    $vg = (Ado GET "$ProjUrl/_apis/distributedtask/variablegroups?groupName=$VarGroupName&$api").value | Select-Object -First 1
    if (-not $vg) {
        $vg = Retry -What 'Key Vault link (federation propagation)' -Tries 10 -DelaySec 20 -Action {
            Ado POST "$Org/_apis/distributedtask/variablegroups?$api" @{
                name = $VarGroupName; type = 'AzureKeyVault'
                description = 'Secrets for Azure Local pipelines'
                providerData = @{
                    serviceEndpointId = $epVms.id
                    vault             = $KeyVaultName
                    lastRefreshedOn   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')   # required by the API
                }
                variables = @{
                    vmAdminPassword    = @{ isSecret = $true; enabled = $true; contentType = '' }
                    domainJoinPassword = @{ isSecret = $true; enabled = $true; contentType = '' }
                }
                variableGroupProjectReferences = @(@{ projectReference = @{ id = $ProjId; name = $AdoProject }; name = $VarGroupName })
            }
        }
        Ok "Created ($($vg.id))"
    } else { Info "Exists ($($vg.id))" }

    Step "Environment '$EnvName' with approval"
    $adoEnv = (Ado GET "$ProjUrl/_apis/pipelines/environments?name=$EnvName&$api").value | Select-Object -First 1
    if (-not $adoEnv) { $adoEnv = Ado POST "$ProjUrl/_apis/pipelines/environments?$api" @{ name = $EnvName; description = 'Azure Local - azlocal-cluster01' } }
    Ok "Environment $($adoEnv.id)"

    $checksUrl = "$ProjUrl/_apis/pipelines/checks/configurations?api-version=7.1-preview.1"
    $checks = (Ado GET "$checksUrl&resourceType=environment&resourceId=$($adoEnv.id)").value
    if (-not ($checks | Where-Object { $_.type.name -eq 'Approval' })) {
        $meAdo = (Ado GET "$Org/_apis/connectionData").authenticatedUser.id
        Ado POST $checksUrl @{
            type = @{ id = '8C6F20A7-A545-4486-9777-F762FAFE0D4D'; name = 'Approval' }
            settings = @{
                approvers = @(@{ id = $meAdo }); executionOrder = 'anyOrder'; minRequiredApprovers = 0
                instructions = 'Review the what-if output in the Validate stage before approving.'
                blockedApprovers = @(); requesterCannotBeApprover = $false
            }
            resource = @{ type = 'environment'; id = "$($adoEnv.id)"; name = $EnvName }
            timeout = 43200
        } | Out-Null
        Ok 'Approval check added (you are the approver)'
    } else { Info 'Approval check exists' }

    Step 'Pipelines'
    $pipes = (Ado GET "$ProjUrl/_apis/pipelines?$api").value
    function Ensure-Pipeline([string]$Name, [string]$Path) {
        $pl = $pipes | Where-Object name -eq $Name | Select-Object -First 1
        if ($pl) { Info "$Name exists ($($pl.id))"; return $pl }
        $pl = Ado POST "$ProjUrl/_apis/pipelines?$api" @{
            name = $Name; folder = '\'
            configuration = @{ type = 'yaml'; path = $Path; repository = @{ id = $repo.id; name = $AdoRepoName; type = 'azureReposGit' } }
        }
        Ok "$Name created ($($pl.id))"; $pl
    }
    $pDeploy = Ensure-Pipeline $PipeDeploy '/pipelines/azure-pipelines.yml'
    $pPr     = Ensure-Pipeline $PipePr     '/pipelines/pr-validation.yml'

    $permUrl = "$ProjUrl/_apis/pipelines/pipelinePermissions"
    $grant = @{ pipelines = @(@{ id = $pDeploy.id; authorized = $true }, @{ id = $pPr.id; authorized = $true }) }
    foreach ($r in @(@('endpoint', $epInfra.id), @('endpoint', $epVms.id), @('variablegroup', $vg.id), @('environment', $adoEnv.id))) {
        Ado PATCH "$permUrl/$($r[0])/$($r[1])?api-version=7.1-preview.1" $grant | Out-Null
    }
    Ok 'Pipelines pre-authorized for service connections, variable group and environment'

    Step 'Branch policy: PR what-if on main'
    $buildPolicyType = '0609b952-1397-4640-95ec-e00a01b2c241'
    $pol = (Ado GET "$ProjUrl/_apis/policy/configurations?repositoryId=$($repo.id)&refName=refs/heads/main&policyType=$buildPolicyType&$api").value |
        Where-Object { $_.settings.buildDefinitionId -eq $pPr.id }
    if (-not $pol) {
        Ado POST "$ProjUrl/_apis/policy/configurations?$api" @{
            isEnabled = $true; isBlocking = $true; type = @{ id = $buildPolicyType }
            settings = @{
                buildDefinitionId = $pPr.id; displayName = 'Azure Local what-if'
                queueOnSourceUpdateOnly = $true; manualQueueOnly = $false; validDuration = 720
                scope = @(@{ repositoryId = $repo.id; refName = 'refs/heads/main'; matchKind = 'exact' })
            }
        } | Out-Null
        Ok 'Build validation policy added'
    } else { Info 'Policy exists' }

    $summary.DevOpsProject  = "$Org/$AdoProject"
    $summary.DeployPipeline = "$ProjUrl/_build?definitionId=$($pDeploy.id)"
}

# =============================================================================
Step 'Done'
$summary.GetEnumerator() | ForEach-Object { '{0,-22} {1}' -f $_.Key, $_.Value } | Write-Host
$outFile = Join-Path $RepoPath 'setup-output.json'
$summary | ConvertTo-Json | Set-Content $outFile
Info "Saved (no secrets) to $outFile"
Write-Host "`nNext: set vmSwitchName + image version in params/infra.bicepparam, commit, and run $PipeDeploy with 'Deploy VMs' unticked first." -ForegroundColor Cyan
