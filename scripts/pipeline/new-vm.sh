#!/usr/bin/env bash
# New VM form (Windows or Linux - taken from the chosen image's osType).
# Inputs (env): P_NAME P_CPU P_MEMGB P_IP P_IMAGE P_LNET P_DISKGB P_JOIN P_RDP P_IPV6
#               P_ATTACH_NSG P_NSG P_SSH_EXT P_SSH_KEY P_SECURE_BOOT P_SHOW_PW
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NAME="$P_NAME"
export OS_TYPE JOIN_EFFECTIVE SSH_KEY="" LNET_ID IMAGE_ID SP_ID NSG_ID="" IP="" PW=""

# ---- Image decides Windows vs Linux ----
OS_TYPE="$(azl image-os "$AZL_RG" "$P_IMAGE")"
info "Image $P_IMAGE is $OS_TYPE"

if [ "$OS_TYPE" = "Windows" ]; then
  [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,14}$ ]] || fail "Windows VM name '$NAME' must be 1-15 letters, numbers or hyphens."
else
  [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,53}$ ]] || fail "Linux VM name '$NAME' must be 1-54 letters, numbers or hyphens."
fi
check_name "VM name" "$NAME"
[ "$(azl exists "$AZL_RG" machine "$NAME")" = "false" ] || fail "A machine called '$NAME' already exists in $AZL_RG."

# ---- Linux specifics ----
JOIN_EFFECTIVE="$P_JOIN"
if [ "$OS_TYPE" = "Linux" ]; then
  if is_true "$P_JOIN"; then
    warn "Domain join is Windows-only in this pipeline - $NAME (Linux) will not be joined. Use realmd/sssd inside the VM if needed."
    JOIN_EFFECTIVE="False"
  fi
  case "${P_SSH_KEY:-none}" in
    ""|none|None) info "Linux sign-in: password (no SSH key given)" ;;
    ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-*) SSH_KEY="$P_SSH_KEY"; info "Linux sign-in: password + SSH key" ;;
    *) fail "SSH public key must start with ssh-rsa, ssh-ed25519 or ecdsa-sha2- (paste the .pub file contents), or be 'none'." ;;
  esac
fi

# ---- Resolve resources ----
LNET_ID="$(azl resolve "$AZL_RG" lnet "$P_LNET")"
IMAGE_ID="$(azl resolve "$AZL_RG" image "$P_IMAGE")"
SP_ID="$(azl resolve "$AZL_RG" storage "$AZL_STORAGE_PATH")"
if is_true "$P_ATTACH_NSG"; then
  [ "$P_NSG" != "(none)" ] || fail "'Attach an NSG' is ticked but no NSG was chosen."
  NSG_ID="$(azl resolve "$AZL_RG" nsg "$P_NSG")"
fi

case "$(lower "$P_IP")" in
  ""|auto)
    FREE="$(azl pool-free "$AZL_RG" "$P_LNET")"
    [ "$FREE" = "-1" ] || [ "$FREE" -ge 1 ] || fail "Logical network $P_LNET has no free IPs in its pool."
    info "IP: next free address from $P_LNET ($FREE free)" ;;
  *) IP="$P_IP"; info "IP: $IP (pinned)" ;;
esac

is_true "$JOIN_EFFECTIVE" && require_domain_join_password

# ---- Local admin password (Key Vault: vm-<name>-admin) ----
SECRET="vm-$(lower "$NAME")-admin"
PW="$(kv_password "$SECRET")"
# Masked in logs unless the form asked for it to be shown
is_true "$P_SHOW_PW" || mask "$PW"

# ---- Results: written whether the deployment succeeds or fails (the VM usually exists either way) ----
report() {
  local rc=$1 ip status connect
  rm -f "${PARAMS:-}"
  is_deploy || return 0
  ip="$(azl nic-ip "$AZL_RG" "$NAME-nic01" 2>/dev/null || echo pending)"
  if [ "$rc" = "0" ]; then status="Succeeded"; else status="FAILED - see the Deploy log; the VM may still be usable"; fi
  if [ "$OS_TYPE" = "Windows" ]; then connect="mstsc /v:$ip   (user .\\$AZL_ADMIN_USER)"; else connect="ssh $AZL_ADMIN_USER@$ip"; fi
  local arcssh=""
  if is_true "${P_SSH_EXT:-False}"; then
    arcssh="az ssh arc --resource-group $AZL_RG --name $NAME --local-user $AZL_ADMIN_USER"
    [ "$OS_TYPE" = "Windows" ] && arcssh="$arcssh   (add --rdp for Remote Desktop over SSH)"
  fi

  summary "## $NAME - $status"
  summary ""
  summary "| | |"
  summary "|---|---|"
  summary "| OS / image | $OS_TYPE / $P_IMAGE |"
  summary "| IP address | \`$ip\` |"
  summary "| Size | $P_CPU vCPU, $P_MEMGB GB |"
  summary "| Network | $P_LNET (NSG: $( [ -n "$NSG_ID" ] && echo "$P_NSG" || echo none )) |"
  summary "| Domain joined | $JOIN_EFFECTIVE |"
  summary "| Remote access | $( [ "$OS_TYPE" = "Windows" ] && echo "RDP $P_RDP" || echo "SSH $P_RDP" ) |"
  summary "| IPv6 off | $P_IPV6 |"
  summary "| Azure Arc SSH | $( is_true "${P_SSH_EXT:-False}" && { [ "$OS_TYPE" = "Windows" ] && echo "OpenSSH for Windows extension" || echo "sshd enabled"; } || echo "not installed" ) |"
  summary "| Local admin user | \`$AZL_ADMIN_USER\` |"
  if is_true "$P_SHOW_PW"; then
    summary "| Local admin password | \`$PW\` |"
  else
    summary "| Local admin password | Key Vault \`$AZL_KEYVAULT\` → secret \`$SECRET\` |"
  fi
  [ -n "$SSH_KEY" ] && summary "| SSH key | added for $AZL_ADMIN_USER |"
  summary ""
  summary "Connect: \`$connect\`"
  [ -n "$arcssh" ] && summary "" && summary "Connect through Azure Arc (no network path needed): \`$arcssh\`"
  summary ""
  summary "Copy the password: \`az keyvault secret show --vault-name $AZL_KEYVAULT -n $SECRET --query value -o tsv | Set-Clipboard\`"
  publish_summary "$NAME"

  echo
  echo "==================== $NAME - $status ===================="
  echo "  OS:        $OS_TYPE ($P_IMAGE)"
  echo "  IP:        $ip"
  echo "  User:      $AZL_ADMIN_USER"
  if is_true "$P_SHOW_PW"; then
    echo "  Password:  $PW"
  else
    echo "  Password:  Key Vault $AZL_KEYVAULT, secret $SECRET"
    echo "             az keyvault secret show --vault-name $AZL_KEYVAULT -n $SECRET --query value -o tsv"
  fi
  echo "  Connect:   $connect"
  [ -n "$arcssh" ] && echo "  Arc SSH:   $arcssh"
  echo "  Details:   run page > Extensions tab > '$NAME'"
  echo "========================================================="
}
trap 'report $?' EXIT

PARAMS="$TMPD/newvm-$NAME.json"
write_params "$PARAMS" "{
  'location': env('AZL_LOCATION'), 'customLocationId': env('AZL_CUSTOM_LOCATION_ID'),
  'name': env('P_NAME'), 'processors': int(env('P_CPU')), 'memoryMB': int(env('P_MEMGB')) * 1024,
  'ipAddress': env('IP'), 'logicalNetworkId': env('LNET_ID'), 'imageId': env('IMAGE_ID'),
  'storagePathId': env('SP_ID'), 'nsgId': env('NSG_ID'),
  'dataDisksGB': [int(env('P_DISKGB'))] if int(env('P_DISKGB', '0')) > 0 else [],
  'adminUsername': env('AZL_ADMIN_USER'), 'adminPassword': env('PW'),
  'osType': env('OS_TYPE'), 'sshPublicKey': env('SSH_KEY'), 'secureBoot': flag('P_SECURE_BOOT'),
  'joinDomain': flag('JOIN_EFFECTIVE'), 'domainToJoin': env('AZL_DOMAIN'), 'domainOUPath': env('AZL_DOMAIN_OU'),
  'domainJoinUserName': env('AZL_DOMAIN_JOIN_USER'), 'domainJoinPassword': env('DOMAIN_JOIN_PASSWORD'),
  'dnsServers': csv('AZL_DNS'), 'disableIPv6': flag('P_IPV6'), 'enableRdp': flag('P_RDP'),
  'installSshExtension': flag('P_SSH_EXT'),
  'tags': {'managedBy': 'azure-devops', 'createdBy': 'new-vm-pipeline', 'os': env('OS_TYPE')},
}"

deploy_template bicep/single-vm.bicep "$PARAMS" "newvm-$NAME"
