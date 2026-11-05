<#
.SYNOPSIS
  Grants the Azure DevOps service connection identities the Azure Local roles they need.

.DESCRIPTION
  - Infra identity  -> "Azure Stack HCI Administrator" on the cluster RG
                       (needed to create logical networks, images, storage paths)
  - VM identity     -> "Azure Stack HCI VM Contributor" on the VM RG
                       + "Azure Stack HCI VM Reader" on the cluster RG if the VM RG is different
                       (so it can reference the custom location / lnets / images)
  - If the domain-join extension fails with AuthorizationFailed, also run with -AddArcExtensionRole.

  Get each AppId from: Project settings > Service connections > <name> > Manage App registration
  (or the Managed identity's client ID if you used a managed identity).

.EXAMPLE
  ./Grant-PipelineRbac.ps1 -SubscriptionId <sub> -ClusterResourceGroup Infrastructure `
     -VmResourceGroup Infrastructure -InfraAppId <guid> -VmAppId <guid>
#>
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ClusterResourceGroup,
    [Parameter(Mandatory)] [string] $VmResourceGroup,
    [Parameter(Mandatory)] [string] $InfraAppId,
    [Parameter(Mandatory)] [string] $VmAppId,
    [switch] $AddArcExtensionRole
)

$ErrorActionPreference = 'Stop'
az account set --subscription $SubscriptionId | Out-Null

$clusterScope = "/subscriptions/$SubscriptionId/resourceGroups/$ClusterResourceGroup"
$vmScope      = "/subscriptions/$SubscriptionId/resourceGroups/$VmResourceGroup"

function Grant($appId, $role, $scope) {
    $oid = az ad sp show --id $appId --query id -o tsv
    Write-Host "Assigning '$role' to $appId on $scope"
    az role assignment create --assignee-object-id $oid --assignee-principal-type ServicePrincipal `
        --role $role --scope $scope --only-show-errors | Out-Null
}

Grant $InfraAppId 'Azure Stack HCI Administrator'  $clusterScope
Grant $VmAppId    'Azure Stack HCI VM Contributor' $vmScope

if ($VmResourceGroup -ne $ClusterResourceGroup) {
    # Needed to deploy against the custom location and use lnets/images in the cluster RG
    Grant $VmAppId 'Azure Stack HCI VM Contributor' $clusterScope
}
if ($AddArcExtensionRole) {
    Grant $VmAppId 'Azure Connected Machine Resource Administrator' $vmScope
}

Write-Host "`nDone. Role assignments can take a few minutes to propagate." -ForegroundColor Green
