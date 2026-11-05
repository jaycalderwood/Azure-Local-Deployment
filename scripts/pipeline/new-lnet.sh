#!/usr/bin/env bash
# New Logical Network form. Inputs (env): P_NAME P_ALLOC P_PREFIX P_GATEWAY P_POOL_START P_POOL_END
#                                         P_DNS P_VLAN P_SWITCH P_NSG
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NAME="$P_NAME"
[[ "$NAME" =~ ^[A-Za-z0-9][-._A-Za-z0-9]{0,62}[A-Za-z0-9]$ ]] || fail "Name '$NAME' must be 2-64 letters, numbers, - . _ and start/end with a letter or number."
check_name "Logical network name" "$NAME"
[ "$(azl exists "$AZL_RG" lnet "$NAME")" = "false" ] || fail "Logical network '$NAME' already exists. Logical networks can't be changed in place - pick a new name."

export NSG_ID="" SWITCH="${P_SWITCH:-}"
[ -n "$SWITCH" ] && [ "$SWITCH" != "default" ] || SWITCH="$AZL_VM_SWITCH"
[ "$P_NSG" = "(none)" ] || NSG_ID="$(azl resolve "$AZL_RG" nsg "$P_NSG")"

if [ "$P_ALLOC" = "Static" ]; then
  for v in P_PREFIX P_GATEWAY P_POOL_START P_POOL_END; do
    [ -n "${!v:-}" ] && [ "${!v}" != "-" ] || fail "Static networks need an address prefix, gateway and IP pool start/end."
  done
  python3 - <<'PY' || fail "Address/gateway/pool values don't fit together - see the message above."
import ipaddress, os, sys
net = ipaddress.ip_network(os.environ["P_PREFIX"], strict=False)
gw, s, e = (ipaddress.ip_address(os.environ[k]) for k in ("P_GATEWAY", "P_POOL_START", "P_POOL_END"))
errs = [f"{n} {v} is outside {net}" for n, v in (("gateway", gw), ("pool start", s), ("pool end", e)) if v not in net]
if s > e: errs.append("pool start is after pool end")
if s <= gw <= e: errs.append("gateway is inside the IP pool")
print("\n".join(errs) or f"OK: {net}, gateway {gw}, pool {s}-{e} ({int(e) - int(s) + 1} addresses)")
sys.exit(1 if errs else 0)
PY
fi

PARAMS="$TMPD/lnet-$NAME.json"; trap 'rm -f "$PARAMS"' EXIT
write_params "$PARAMS" "{
  'name': env('P_NAME'), 'location': env('AZL_LOCATION'), 'customLocationId': env('AZL_CUSTOM_LOCATION_ID'),
  'vmSwitchName': env('SWITCH'), 'ipAllocationMethod': env('P_ALLOC'),
  'addressPrefix': env('P_PREFIX') if env('P_ALLOC') == 'Static' else '',
  'defaultGateway': env('P_GATEWAY') if env('P_ALLOC') == 'Static' else '',
  'ipPoolStart': env('P_POOL_START') if env('P_ALLOC') == 'Static' else '',
  'ipPoolEnd': env('P_POOL_END') if env('P_ALLOC') == 'Static' else '',
  'dnsServers': [d for d in csv('P_DNS') if d != '-'], 'vlanId': int(env('P_VLAN', '0')), 'nsgId': env('NSG_ID'),
  'tags': {'managedBy': 'azure-devops', 'createdBy': 'new-lnet-pipeline'},
}"

deploy_template bicep/modules/logicalNetwork.bicep "$PARAMS" "newlnet-$NAME"
is_deploy || exit 0

summary "## Logical network $NAME created"
summary ""
summary "| | |"
summary "|---|---|"
summary "| Allocation | $P_ALLOC |"
[ "$P_ALLOC" = "Static" ] && summary "| Subnet / gateway | $P_PREFIX via $P_GATEWAY |" && summary "| VM IP pool | $P_POOL_START - $P_POOL_END |"
summary "| VLAN | $( [ "$P_VLAN" = "0" ] && echo untagged || echo "$P_VLAN" ) |"
summary "| DNS | ${P_DNS} |"
summary "| VM switch | $SWITCH |"
summary "| NSG | $P_NSG |"
summary ""
summary "The next step of this run refreshes the form dropdowns, so $NAME appears in the New VM / NSG / AVD / AKS forms."
publish_summary
