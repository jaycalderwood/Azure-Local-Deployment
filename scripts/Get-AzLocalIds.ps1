<#
.SYNOPSIS
  Prints the IDs you need for the .bicepparam files (custom location, storage paths,
  logical networks, images) using Azure CLI. Run from any machine with az + login.

.EXAMPLE
  ./Get-AzLocalIds.ps1 -SubscriptionId <sub> -ClusterResourceGroup Infrastructure

.NOTES
  vmSwitchName is NOT in Azure. Get it on a cluster node:  Get-VMSwitch | Select Name, SwitchType
#>
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ClusterResourceGroup
)

$ErrorActionPreference = 'Stop'
az account set --subscription $SubscriptionId | Out-Null

function Show($title, $type) {
    Write-Host "`n== $title ($type)" -ForegroundColor Cyan
    az resource list -g $ClusterResourceGroup --resource-type $type --query "[].{name:name, id:id}" -o table
}

Write-Host "Region:" (az group show -n $ClusterResourceGroup --query location -o tsv)
Show 'Custom location'   'Microsoft.ExtendedLocation/customLocations'
Show 'Arc resource bridge' 'Microsoft.ResourceConnector/appliances'
Show 'Storage paths'     'Microsoft.AzureStackHCI/storageContainers'
Show 'Logical networks'  'Microsoft.AzureStackHCI/logicalNetworks'
Show 'Marketplace images' 'Microsoft.AzureStackHCI/marketplaceGalleryImages'
Show 'Custom images'     'Microsoft.AzureStackHCI/galleryImages'

Write-Host "`nResource bridge status:" -ForegroundColor Cyan
az resource list -g $ClusterResourceGroup --resource-type Microsoft.ResourceConnector/appliances `
  --query "[].{name:name, status:properties.status}" -o table
