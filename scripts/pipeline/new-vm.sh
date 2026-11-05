#!/usr/bin/env bash
# New VM form. Inputs (env): P_NAME P_CPU P_MEMGB P_IP P_IMAGE P_LNET P_DISKGB P_JOIN P_RDP P_IPV6
#                            P_ATTACH_NSG P_NSG P_SHOW_PW
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NAME="$P_NAME"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,14}$ ]] || fail "VM name '$NAME' must be 1-15 letters, numbers or hyphens."
check_name "VM name" "$NAME"
[ "$(azl exists "$AZL_RG" machine "$NAME")" = "false" ] || fail "A machine called '$NAME' already exists in $AZL_RG."

export LNET_ID IMAGE_ID SP_ID NSG_ID="" IP="" PW
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

is_true "$P_JOIN" && require_domain_join_password

SECRET="vm-$(lower "$NAME")-admin"
PW="$(kv_password "$SECRET")"; mask "$PW"

PARAMS="$TMPD/newvm-$NAME.json"; trap 'rm -f "$PARAMS"' EXIT
write_params "$PARAMS" "{
  'location': env('AZL_LOCATION'), 'customLocationId': env('AZL_CUSTOM_LOCATION_ID'),
  'name': env('P_NAME'), 'processors': int(env('P_CPU')), 'memoryMB': int(env('P_MEMGB')) * 1024,
  'ipAddress': env('IP'), 'logicalNetworkId': env('LNET_ID'), 'imageId': env('IMAGE_ID'),
  'storagePathId': env('SP_ID'), 'nsgId': env('NSG_ID'),
  'dataDisksGB': [int(env('P_DISKGB'))] if int(env('P_DISKGB', '0')) > 0 else [],
  'adminUsername': env('AZL_ADMIN_USER'), 'adminPassword': env('PW'),
  'joinDomain': flag('P_JOIN'), 'domainToJoin': env('AZL_DOMAIN'), 'domainOUPath': env('AZL_DOMAIN_OU'),
  'domainJoinUserName': env('AZL_DOMAIN_JOIN_USER'), 'domainJoinPassword': env('DOMAIN_JOIN_PASSWORD'),
  'dnsServers': csv('AZL_DNS'), 'disableIPv6': flag('P_IPV6'), 'enableRdp': flag('P_RDP'),
  'tags': {'managedBy': 'azure-devops', 'createdBy': 'new-vm-pipeline'},
}"

deploy_template bicep/single-vm.bicep "$PARAMS" "newvm-$NAME"
is_deploy || exit 0

ACTUAL_IP="$(azl nic-ip "$AZL_RG" "$NAME-nic01")"
summary "## $NAME is ready"
summary ""
summary "| | |"
summary "|---|---|"
summary "| IP address | \`$ACTUAL_IP\` |"
summary "| Size | $P_CPU vCPU, $P_MEMGB GB |"
summary "| Image / network | $P_IMAGE on $P_LNET |"
summary "| NSG on NIC | $( [ -n "$NSG_ID" ] && echo "$P_NSG" || echo none ) |"
summary "| Domain joined | $P_JOIN |"
summary "| RDP enabled | $P_RDP |"
summary "| IPv6 off | $P_IPV6 |"
summary "| Local admin | \`.\\$AZL_ADMIN_USER\` |"
if is_true "$P_SHOW_PW"; then
  summary "| Password | \`$PW\` |"
else
  summary "| Password | Key Vault \`$AZL_KEYVAULT\` → \`$SECRET\` |"
fi
summary ""
summary "Copy the password: \`az keyvault secret show --vault-name $AZL_KEYVAULT -n $SECRET --query value -o tsv | Set-Clipboard\`"
summary ""
summary "Connect: \`mstsc /v:$ACTUAL_IP\`"
publish_summary
info "VM $NAME  IP $ACTUAL_IP  password secret: $SECRET"
