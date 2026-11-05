#!/usr/bin/env bash
# New/Update NSG form. Inputs (env): P_EXISTING P_NEW_NAME P_RULESET P_MGMT_CIDR P_ATTACH_LNET P_CONFIRM_IN_USE
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [ "$P_EXISTING" = "(new)" ]; then
  NAME="$P_NEW_NAME"
  [[ "$NAME" =~ ^[A-Za-z0-9][-._A-Za-z0-9]{0,62}[A-Za-z0-9]$ ]] || fail "New NSG name '$NAME' must be 2-64 letters, numbers, - . _"
  check_name "NSG name" "$NAME"
  [ "$(azl exists "$AZL_RG" nsg "$NAME")" = "false" ] || fail "NSG '$NAME' already exists - pick it from the 'Existing NSG' list instead."
  IS_NEW=true
else
  NAME="$P_EXISTING"; IS_NEW=false
  azl resolve "$AZL_RG" nsg "$NAME" >/dev/null
fi

RULESET="${P_RULESET%% *}"            # "Windows-Server-Baseline (RDP, ping, WinRM ...)" -> "Windows-Server-Baseline"
MGMT="${P_MGMT_CIDR:-$AZL_MGMT_CIDR}"
python3 -c "import ipaddress,sys; ipaddress.ip_network(sys.argv[1], strict=False)" "$MGMT" 2>/dev/null \
  || fail "Management source '$MGMT' isn't a valid CIDR (e.g. 10.1.10.0/24)."
export NAME RULESET MGMT

if [ "$RULESET" != "None" ] || [ "$IS_NEW" = true ]; then
  PARAMS="$TMPD/nsg-$NAME.json"; trap 'rm -f "$PARAMS"' EXIT
  write_params "$PARAMS" "{
    'name': env('NAME'), 'location': env('AZL_LOCATION'), 'customLocationId': env('AZL_CUSTOM_LOCATION_ID'),
    'ruleSet': env('RULESET'), 'managementCidr': env('MGMT'),
    'tags': {'managedBy': 'azure-devops', 'createdBy': 'new-nsg-pipeline'},
  }"
  deploy_template bicep/modules/nsg.bicep "$PARAMS" "newnsg-$NAME"
else
  info "Rule set 'None' on an existing NSG - rules left as they are."
fi

ATTACHED=""
if [ "$P_ATTACH_LNET" != "(none)" ]; then
  INFO="$(azl lnet-info "$AZL_RG" "$P_ATTACH_LNET")"
  LNET_ID="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$INFO")"
  CURRENT="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['nsg'] or '')" "$INFO")"
  IN_USE="$(azl nics-on "$AZL_RG" "$LNET_ID")"
  COUNT="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$IN_USE")"
  [ -z "$CURRENT" ] || warn "$P_ATTACH_LNET already has NSG $(basename "$CURRENT") - it will be replaced by $NAME."
  if [ "$COUNT" -gt 0 ]; then
    warn "$COUNT NIC(s) already on $P_ATTACH_LNET will get $NAME's rules immediately: $IN_USE"
    is_true "${P_CONFIRM_IN_USE:-false}" || fail "Tick 'I understand existing VMs on that network are affected' to attach $NAME to $P_ATTACH_LNET."
  fi
  if is_deploy; then
    NSG_ID="$(azl resolve "$AZL_RG" nsg "$NAME")"
    info "Attaching $NAME to logical network $P_ATTACH_LNET"
    az stack-hci-vm network lnet update -g "$AZL_RG" --name "$P_ATTACH_LNET" --network-security-group "$NSG_ID" -o none
    ATTACHED="$P_ATTACH_LNET"
  else
    info "Would attach $NAME to logical network $P_ATTACH_LNET ($COUNT NIC(s) on it)"
  fi
fi
is_deploy || exit 0

summary "## NSG $NAME $( [ "$IS_NEW" = true ] && echo created || echo updated )"
summary ""
summary "| | |"
summary "|---|---|"
summary "| Rule set | $RULESET |"
summary "| Management source | $MGMT |"
summary "| Attached to logical network | ${ATTACHED:-not attached} |"
summary ""
summary "Rules now on the NSG:"
summary ""
summary '```'
az stack-hci-vm network nsg rule list -g "$AZL_RG" --nsg-name "$NAME" -o json 2>/dev/null \
  | python3 -c "
import json,sys
rows=json.load(sys.stdin)
fmt=lambda r: '{:<5} {:<9} {:<6} {:<5} {:<24} {}'.format(r['properties']['priority'], r['properties']['direction'], r['properties']['access'], r['properties']['protocol'], ','.join(r['properties'].get('destinationPortRanges') or ['*']), r['name'])
print('\\n'.join(fmt(r) for r in sorted(rows, key=lambda r: r['properties']['priority'])))" >> "$SUMMARY_FILE" \
  || summary "(rule listing not available - open the NSG in the portal)"
summary '```'
publish_summary
