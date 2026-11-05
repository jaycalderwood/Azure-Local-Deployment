#!/usr/bin/env bash
# Shared helpers for scripts/pipeline/*.sh. Sourced, not run.
set -euo pipefail

MODE="${MODE:?MODE must be whatif, deploy or run}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
TMPD="${AGENT_TEMPDIRECTORY:-$(mktemp -d)}"
cd "$REPO_DIR"

az config set extension.use_dynamic_install=yes_without_prompt extension.dynamic_install_allow_preview=true \
  --only-show-errors >/dev/null 2>&1 || true
az bicep install --only-show-errors >/dev/null 2>&1 || true

azl()      { python3 "$SCRIPTS_DIR/azl.py" "$@"; }
fail()     { echo "##vso[task.logissue type=error]$*"; echo "ERROR: $*" >&2; exit 1; }
warn()     { echo "##vso[task.logissue type=warning]$*"; }
info()     { echo ">> $*"; }
is_true()  { [ "$(printf %s "${1:-}" | tr '[:upper:]' '[:lower:]')" = "true" ]; }
lower()    { printf %s "$1" | tr '[:upper:]' '[:lower:]'; }
mask()     { [ -n "${1:-}" ] && echo "##vso[task.setvariable variable=masked_${RANDOM};issecret=true]$1"; return 0; }
is_deploy(){ [ "$MODE" = "deploy" ]; }

# check_name <what> <name>: Azure rejects trademarked/reserved words in resource names (ReservedResourceName)
check_name() {
  local what="$1" n; n="$(lower "$2")"
  case "$n" in *microsoft*|*windows*) fail "$what '$2' can't contain 'microsoft' or 'windows' anywhere (Azure reserved word).";; esac
  case "$n" in login*|xbox*) fail "$what '$2' can't start with 'login' or 'xbox' (Azure reserved word).";; esac
  case "$n" in access|app_code|app_store|azure|bing|bizspark|biztalk|cortana|directx|dotnet|dynamics|excel|exchange|forefront|\
               groove|hololens|hyperv|kinect|lync|msdn|o365|office|office365|onedrive|onenote|outlook|powerpoint|sharepoint|\
               skype|visio|visualstudio)
      fail "$what '$2' is an Azure reserved word - pick another name.";;
  esac
  return 0
}

new_password() {
  python3 -c "import secrets,string; a=string.ascii_letters+string.digits; print(''.join(secrets.choice(a) for _ in range(20))+'aZ7!')"
}

# kv_password <secret-name>: prints the password stored in Key Vault, creating it first if needed.
# In whatif mode it never touches Key Vault and prints a placeholder.
kv_password() {
  local secret="$1" pw
  if ! is_deploy; then echo 'WhatIf-Placeholder-1!'; return; fi
  pw="$(az keyvault secret show --vault-name "$AZL_KEYVAULT" -n "$secret" --query value -o tsv 2>/dev/null || true)"
  if [ -z "$pw" ]; then
    pw="$(new_password)"
    az keyvault secret set --vault-name "$AZL_KEYVAULT" -n "$secret" --value "$pw" \
      --tags createdBy=azure-devops -o none --only-show-errors
    echo "Created Key Vault secret $secret" >&2
  else
    echo "Reusing Key Vault secret $secret" >&2
  fi
  printf %s "$pw"      # caller must run: mask "$PW"  (logging commands are only read from stdout)
}

require_domain_join_password() {
  case "${DOMAIN_JOIN_PASSWORD:-}" in
    ""|"not-used"|'$(domainJoinPassword)')
      fail "Domain join needs the real password in Key Vault: az keyvault secret set --vault-name $AZL_KEYVAULT -n domainJoinPassword --value '<pw>'" ;;
  esac
}

# deploy_template <template> <params-file> <deployment-name>
deploy_template() {
  local tpl="$1" params="$2" name="$3"
  if is_deploy; then
    info "Deploying $tpl as '$name'"
    az deployment group create -g "$AZL_RG" -n "$name" --template-file "$tpl" --parameters "@$params" -o none
  else
    info "What-if for $tpl"
    az deployment group what-if -g "$AZL_RG" -n "$name" --template-file "$tpl" --parameters "@$params"
  fi
}

# write_params <outfile> <python-dict-expression using env()>   (values come from env vars, never inlined)
write_params() {
  local out="$1" expr="$2"
  python3 -c "
import json, os
def env(k, d=''): return os.environ.get(k, d)
def flag(k): return env(k).lower() == 'true'
def csv(k): return [x.strip() for x in env(k).replace(';', ',').split(',') if x.strip()]
print(json.dumps($expr))" | azl params "$out"
}

SUMMARY_FILE="$TMPD/summary-$RANDOM.md"
summary()        { printf '%s\n' "$*" >> "$SUMMARY_FILE"; }
publish_summary(){ [ -s "$SUMMARY_FILE" ] && echo "##vso[task.uploadsummary]$SUMMARY_FILE"; return 0; }
