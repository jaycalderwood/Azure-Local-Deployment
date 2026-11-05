#!/usr/bin/env bash
# Refresh the dropdown lists in the form pipelines from what exists in Azure, then commit to main.
# Works on a fresh worktree of origin/main, so it is safe to run at the end of any pipeline run
# even if main has moved on since that run started.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

LISTS="$TMPD/dropdowns.json"
python3 - "$LISTS" "$SCRIPTS_DIR/azl.py" "$AZL_RG" <<'PY'
import json, subprocess, sys
out, azl, rg = sys.argv[1:4]
def names(kind):
    return json.loads(subprocess.check_output(["python3", azl, "names", rg, kind], text=True))
json.dump({"lnets": names("lnet"), "nsgs": names("nsg"), "images": names("image"), "hostpools": names("hostpool")},
          open(out, "w"))
PY
info "Found in $AZL_RG: $(cat "$LISTS")"

BRANCH="main"
WT="$TMPD/dropdown-sync-$RANDOM"
git fetch -q origin "$BRANCH"
git worktree add -q --detach "$WT" "origin/$BRANCH"
trap 'git worktree remove --force "$WT" >/dev/null 2>&1 || true' EXIT

( cd "$WT" && python3 "$SCRIPTS_DIR/sync_dropdowns.py" "$LISTS" pipelines/*.yml )

if git -C "$WT" diff --quiet -- pipelines; then
  info "Dropdowns already match Azure - nothing to commit."
  exit 0
fi

git -C "$WT" -c user.email="azure-pipelines@contoso.com" -c user.name="Sync Dropdowns" \
  commit -q -am "Sync form dropdowns with Azure Local resources [skip ci]"
info "Pushing updated dropdowns to $BRANCH"
git -C "$WT" push -q origin "HEAD:$BRANCH" \
  || fail "Push was refused. Give '<project> Build Service' Contribute + 'Bypass policies when pushing' on the repo (scripts/Add-AzureLocalPipelines.ps1 does this)."
info "Done - re-open a form to see the new choices."
