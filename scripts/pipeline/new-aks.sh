#!/usr/bin/env bash
# New AKS cluster form (AKS enabled by Azure Arc on Azure Local).
# Inputs (env): P_NAME P_LNET P_ADMIN_GROUP P_CP_COUNT P_NODE_COUNT P_NODE_SIZE P_K8S_VERSION
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NAME="$P_NAME"
[[ "$NAME" =~ ^[a-z][a-z0-9-]{1,38}[a-z0-9]$ ]] || fail "Cluster name '$NAME' must be 3-40 lowercase letters, numbers or hyphens."
check_name "Cluster name" "$NAME"
[[ "$P_ADMIN_GROUP" =~ ^[0-9a-fA-F-]{36}$ ]] || fail "Admin group must be an Entra group object ID (GUID). Members get cluster-admin; add yourself to it."

info "Installing the aksarc / connectedk8s CLI extensions"
az extension add -n aksarc --upgrade -y --only-show-errors
az extension add -n connectedk8s --upgrade -y --only-show-errors

INFO="$(azl lnet-info "$AZL_RG" "$P_LNET")"
LNET_ID="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$INFO")"
ALLOC="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['ipAllocationMethod'] or '')" "$INFO")"
[ "$ALLOC" = "Static" ] || fail "AKS needs a Static logical network; $P_LNET is '$ALLOC'."

NEED=$((P_CP_COUNT + P_NODE_COUNT + 2))     # every node VM + 1 for rolling upgrades + 1 control-plane IP
FREE="$(azl pool-free "$AZL_RG" "$P_LNET")"
info "IP plan: $P_CP_COUNT control plane + $P_NODE_COUNT workers + 2 = $NEED IPs from $P_LNET (free: $FREE)"
[ "$FREE" = "-1" ] || [ "$FREE" -ge "$NEED" ] || fail "$P_LNET only has $FREE free IPs; this cluster needs $NEED. Use a bigger logical network or fewer nodes."

[ "$(az resource list -g "$AZL_RG" --resource-type Microsoft.Kubernetes/connectedClusters --query "[?name=='$NAME'] | length(@)" -o tsv)" = "0" ] \
  || fail "A cluster called '$NAME' already exists."

ARGS=(-n "$NAME" -g "$AZL_RG" --custom-location "$AZL_CUSTOM_LOCATION_ID" --vnet-ids "$LNET_ID"
      --aad-admin-group-object-ids "$P_ADMIN_GROUP"
      --control-plane-count "$P_CP_COUNT" --node-count "$P_NODE_COUNT" --node-vm-size "$P_NODE_SIZE")
[ "$P_K8S_VERSION" = "default" ] || ARGS+=(--kubernetes-version "$P_K8S_VERSION")

# ---- SSH key for the node VMs, kept in Key Vault ----
KEY="$TMPD/aks-$NAME"; trap 'rm -f "$KEY" "$KEY.pub"' EXIT
SECRET="aks-$NAME-ssh"
if is_deploy; then
  PUB="$(az keyvault secret show --vault-name "$AZL_KEYVAULT" -n "$SECRET-pub" --query value -o tsv 2>/dev/null || true)"
  if [ -z "$PUB" ]; then
    ssh-keygen -q -t rsa -b 4096 -N '' -C "aks-$NAME" -f "$KEY"
    az keyvault secret set --vault-name "$AZL_KEYVAULT" -n "$SECRET" --file "$KEY" -o none --only-show-errors
    az keyvault secret set --vault-name "$AZL_KEYVAULT" -n "$SECRET-pub" --file "$KEY.pub" -o none --only-show-errors
    info "SSH key pair stored in Key Vault as $SECRET / $SECRET-pub"
  else
    printf '%s\n' "$PUB" > "$KEY.pub"
  fi
else
  ssh-keygen -q -t rsa -b 2048 -N '' -f "$KEY"
fi
ARGS+=(--ssh-key-value "$KEY.pub")

if ! is_deploy; then
  info "Plan: az aksarc create ${ARGS[*]}"
  if az aksarc create --help 2>/dev/null | grep -q -- '--validate'; then
    info "Validating with az aksarc create --validate"
    az aksarc create "${ARGS[@]}" --validate -o none
  else
    info "(this aksarc version has no --validate; inputs checked above)"
  fi
  exit 0
fi

info "Creating AKS cluster $NAME - typically 20-40 minutes"
az aksarc create "${ARGS[@]}" -o none

summary "## AKS cluster $NAME is ready"
summary ""
summary "| | |"
summary "|---|---|"
summary "| Control plane / workers | $P_CP_COUNT / $P_NODE_COUNT x $P_NODE_SIZE |"
summary "| Logical network | $P_LNET |"
summary "| Admin group | \`$P_ADMIN_GROUP\` |"
summary "| Node SSH key | Key Vault \`$AZL_KEYVAULT\` → \`$SECRET\` |"
summary ""
summary "Connect (as a member of the admin group):"
summary ""
summary '```powershell'
summary "az extension add -n aksarc; az extension add -n connectedk8s"
summary "az aksarc get-credentials -n $NAME -g $AZL_RG"
summary "kubectl get nodes"
summary "# or from anywhere, through Azure Arc:"
summary "az connectedk8s proxy -n $NAME -g $AZL_RG"
summary '```'
publish_summary
