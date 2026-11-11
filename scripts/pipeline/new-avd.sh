#!/usr/bin/env bash
# New AVD session hosts form. Inputs (env): P_HOSTPOOL P_NEW_HOSTPOOL P_POOL_TYPE P_MAX_SESSIONS P_COUNT P_PREFIX
#                                           P_CPU P_MEMGB P_IMAGE P_LNET P_ATTACH_NSG P_NSG P_IPV6
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
API="2024-04-03"

PREFIX="$P_PREFIX"
[[ "$PREFIX" =~ ^[A-Za-z][A-Za-z0-9]{0,10}$ ]] || fail "Name prefix '$PREFIX' must be 1-11 letters/numbers (hosts become PREFIX-01, PREFIX-02 ...)."
check_name "Host name prefix" "$PREFIX"
require_domain_join_password

# ---- Host pool ----
if [ "$P_HOSTPOOL" = "(new)" ]; then
  HP="$P_NEW_HOSTPOOL"
  [[ "$HP" =~ ^[A-Za-z0-9][-._A-Za-z0-9]{1,62}$ ]] || fail "New host pool name '$HP' must be 2-64 letters, numbers, - . _"
  check_name "Host pool name" "$HP"
  [ "$(azl exists "$AZL_RG" hostpool "$HP")" = "false" ] || fail "Host pool '$HP' already exists - pick it from the list instead."
  NEW_POOL=true
else
  HP="$P_HOSTPOOL"; NEW_POOL=false
fi
export HP

# ---- Names, network, image ----
export LNET_ID IMAGE_ID SP_ID NSG_ID=""
LNET_ID="$(azl resolve "$AZL_RG" lnet "$P_LNET")"
IMAGE_ID="$(azl resolve "$AZL_RG" image "$P_IMAGE")"
[ "$(azl image-os "$AZL_RG" "$P_IMAGE")" = "Windows" ] || fail "AVD session hosts need a Windows image (ideally Windows 11 multi-session); $P_IMAGE is Linux."
SP_ID="$(azl resolve "$AZL_RG" storage "$AZL_STORAGE_PATH")"
if is_true "$P_ATTACH_NSG"; then
  [ "$P_NSG" != "(none)" ] || fail "'Attach an NSG' is ticked but no NSG was chosen."
  NSG_ID="$(azl resolve "$AZL_RG" nsg "$P_NSG")"
fi

START="$(azl next-index "$AZL_RG" "$PREFIX")"
HOSTS=()
for ((i = 0; i < P_COUNT; i++)); do HOSTS+=("$(printf '%s-%02d' "$PREFIX" $((START + i)))"); done
info "Session hosts: ${HOSTS[*]}"

FREE="$(azl pool-free "$AZL_RG" "$P_LNET")"
[ "$FREE" = "-1" ] || [ "$FREE" -ge "$P_COUNT" ] || fail "$P_LNET has $FREE free IPs; $P_COUNT hosts need $P_COUNT."

# ---- Host pool + app group + workspace ----
if [ "$NEW_POOL" = true ]; then
  HPPARAMS="$TMPD/hp-$HP.json"
  write_params "$HPPARAMS" "{
    'hostPoolName': env('HP'), 'location': env('AZL_LOCATION'), 'hostPoolType': env('P_POOL_TYPE'),
    'maxSessionLimit': int(env('P_MAX_SESSIONS')), 'tags': {'managedBy': 'azure-devops', 'createdBy': 'new-avd-pipeline'},
  }"
  deploy_template bicep/avd-hostpool.bicep "$HPPARAMS" "avdpool-$HP"
  rm -f "$HPPARAMS"
fi

# ---- Registration token (deploy only) ----
TOKEN='whatif-placeholder-token'
if is_deploy; then
  HP_ID="$(azl resolve "$AZL_RG" hostpool "$HP")"
  EXP="$(date -u -d '+6 hours' +%Y-%m-%dT%H:%M:%SZ)"
  info "Creating a registration token for $HP (valid until $EXP)"
  az rest --method patch --url "https://management.azure.com${HP_ID}?api-version=$API" \
    --body "{\"properties\":{\"registrationInfo\":{\"expirationTime\":\"$EXP\",\"registrationTokenOperation\":\"Update\"}}}" -o none
  TOKEN="$(az rest --method post --url "https://management.azure.com${HP_ID}/retrieveRegistrationToken?api-version=$API" \
            --query token -o tsv 2>/dev/null || true)"
  if [ -z "$TOKEN" ]; then
    TOKEN="$(az rest --method post --url "https://management.azure.com${HP_ID}/listRegistrationTokens?api-version=$API" \
              --query "value[0].token" -o tsv)"
  fi
  [ -n "$TOKEN" ] || fail "Could not get a registration token for host pool $HP."
fi
mask "$TOKEN"
export TOKEN

# ---- Per-host admin passwords ----
PWJSON="{}"
for h in "${HOSTS[@]}"; do
  pw="$(kv_password "vm-$(lower "$h")-admin")"; mask "$pw"
  PWJSON="$(H="$h" PW="$pw" python3 -c "import json,os,sys; d=json.loads(sys.argv[1]); d[os.environ['H']]=os.environ['PW']; print(json.dumps(d))" "$PWJSON")"
done
export PWJSON
export HOSTS_JSON; HOSTS_JSON="$(printf '%s\n' "${HOSTS[@]}" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().split()))")"

PARAMS="$TMPD/avd-$PREFIX.json"; trap 'rm -f "$PARAMS"' EXIT
write_params "$PARAMS" "{
  'location': env('AZL_LOCATION'), 'customLocationId': env('AZL_CUSTOM_LOCATION_ID'),
  'hostNames': json.loads(env('HOSTS_JSON')), 'processors': int(env('P_CPU')), 'memoryMB': int(env('P_MEMGB')) * 1024,
  'logicalNetworkId': env('LNET_ID'), 'imageId': env('IMAGE_ID'), 'storagePathId': env('SP_ID'), 'nsgId': env('NSG_ID'),
  'adminUsername': env('AZL_ADMIN_USER'), 'adminPasswords': json.loads(env('PWJSON')),
  'avdRegistrationToken': env('TOKEN'),
  'domainToJoin': env('AZL_DOMAIN'), 'domainOUPath': env('AZL_DOMAIN_OU'),
  'domainJoinUserName': env('AZL_DOMAIN_JOIN_USER'), 'domainJoinPassword': env('DOMAIN_JOIN_PASSWORD'),
  'dnsServers': csv('AZL_DNS'), 'disableIPv6': flag('P_IPV6'),
  'tags': {'managedBy': 'azure-devops', 'createdBy': 'new-avd-pipeline', 'avdHostPool': env('HP')},
}"
deploy_template bicep/avd-hosts.bicep "$PARAMS" "avdhosts-$PREFIX-$START"
is_deploy || exit 0

AG_ID="$(az resource list -g "$AZL_RG" --resource-type Microsoft.DesktopVirtualization/applicationGroups -o json \
  | python3 -c "import json,sys; hp=sys.argv[1].lower(); print(next((a['id'] for a in json.load(sys.stdin) if a['name'].lower()==hp+'-dag'), ''))" "$HP")"

summary "## AVD session hosts added to $HP"
summary ""
summary "| Host | IP | Password secret |"
summary "|---|---|---|"
for h in "${HOSTS[@]}"; do
  summary "| $h | \`$(azl nic-ip "$AZL_RG" "$h-nic01")\` | \`vm-$(lower "$h")-admin\` |"
done
summary ""
summary "Hosts register with the host pool after the domain-join reboot (a few minutes). Check **Azure Virtual Desktop → Host pools → $HP → Session hosts** for **Available**."
summary ""
summary "**Give users access** (once per host pool) - assign an Entra group to the desktop application group:"
summary ""
summary '```powershell'
summary "az role assignment create --role \"Desktop Virtualization User\" --assignee-object-id <group-object-id> --assignee-principal-type Group --scope ${AG_ID:-<application-group-id>}"
summary '```'
summary ""
summary "Users then connect with the Windows App / Remote Desktop client or https://windows.cloud.microsoft."
publish_summary "$HP"
