#!/usr/bin/env python3
"""Small helpers for the Azure Local pipeline scripts (runs on the pipeline agent, uses az CLI).

  azl.py resolve   <rg> <kind> <name>   -> resource ID (exit 2 + message if not found)
  azl.py names     <rg> <kind>          -> JSON list of names
  azl.py exists    <rg> <kind> <name>   -> "true" / "false"
  azl.py pool-free <rg> <lnet>          -> free IPs left in the logical network's pools (-1 if unknown)
  azl.py lnet-info <rg> <lnet>          -> JSON: allocation method, prefix, pools
  azl.py next-index <rg> <prefix>       -> next free N for machines named <prefix>-NN
  azl.py nics-on   <rg> <lnetId>        -> JSON list of NIC names attached to that logical network
  azl.py nic-ip    <rg> <nicName>       -> IP address of a NIC ("pending" if none yet)
  azl.py image-os  <rg> <image>         -> Windows / Linux (from the image's osType)
  azl.py params    <outfile>            -> reads a JSON object on stdin, writes an ARM parameters file
"""
import json
import re
import subprocess
import sys

KINDS = {
    "lnet": ["Microsoft.AzureStackHCI/logicalNetworks"],
    "nsg": ["Microsoft.AzureStackHCI/networkSecurityGroups"],
    "image": ["Microsoft.AzureStackHCI/marketplaceGalleryImages", "Microsoft.AzureStackHCI/galleryImages"],
    "storage": ["Microsoft.AzureStackHCI/storageContainers"],
    "hostpool": ["Microsoft.DesktopVirtualization/hostPools"],
    "machine": ["Microsoft.HybridCompute/machines"],
    "nic": ["Microsoft.AzureStackHCI/networkInterfaces"],
}


def az(*args, allow_fail=False):
    r = subprocess.run(["az", *args, "-o", "json", "--only-show-errors"], capture_output=True, text=True)
    if r.returncode != 0:
        if allow_fail:
            return None
        sys.stderr.write(r.stderr)
        sys.exit(r.returncode)
    return json.loads(r.stdout) if r.stdout.strip() else None


def list_kind(rg, kind):
    out = []
    for t in KINDS[kind]:
        out += az("resource", "list", "-g", rg, "--resource-type", t) or []
    return out


def find(rg, kind, name):
    for r in list_kind(rg, kind):
        if r["name"].lower() == name.lower():
            return r
    return None


def show(rid):
    return az("resource", "show", "--ids", rid)


def subnet_props(lnet):
    subs = (lnet.get("properties") or {}).get("subnets") or []
    return (subs[0].get("properties") or {}) if subs else {}


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    cmd, a = argv[1], argv[2:]

    if cmd == "resolve":
        rg, kind, name = a
        r = find(rg, kind, name)
        if not r:
            have = ", ".join(sorted(x["name"] for x in list_kind(rg, kind))) or "(none)"
            sys.stderr.write(f"{kind} '{name}' not found in {rg}. Available: {have}\n")
            return 2
        print(r["id"])
    elif cmd == "names":
        rg, kind = a
        print(json.dumps(sorted({x["name"] for x in list_kind(rg, kind)}, key=str.lower)))
    elif cmd == "exists":
        rg, kind, name = a
        print("true" if find(rg, kind, name) else "false")
    elif cmd in ("pool-free", "lnet-info"):
        rg, name = a
        r = find(rg, "lnet", name)
        if not r:
            sys.stderr.write(f"logical network '{name}' not found\n")
            return 2
        sp = subnet_props(show(r["id"]))
        pools = sp.get("ipPools") or []
        if cmd == "pool-free":
            free = [int((p.get("info") or {}).get("available", -1)) for p in pools]
            print(sum(f for f in free if f >= 0) if free and all(f >= 0 for f in free) else -1)
        else:
            print(json.dumps({
                "id": r["id"],
                "ipAllocationMethod": sp.get("ipAllocationMethod"),
                "addressPrefix": sp.get("addressPrefix"),
                "ipPools": [{"start": p.get("start"), "end": p.get("end"), **(p.get("info") or {})} for p in pools],
                "nsg": (sp.get("networkSecurityGroup") or {}).get("id"),
            }))
    elif cmd == "next-index":
        rg, prefix = a
        rx = re.compile(rf"^{re.escape(prefix)}-(\d+)$", re.I)
        used = [int(m.group(1)) for x in list_kind(rg, "machine") if (m := rx.match(x["name"]))]
        print(max(used, default=0) + 1)
    elif cmd == "nics-on":
        rg, lnet_id = a
        names = []
        for n in list_kind(rg, "nic"):
            p = (show(n["id"]) or {}).get("properties") or {}
            for ipc in p.get("ipConfigurations") or []:
                sid = (((ipc.get("properties") or {}).get("subnet")) or {}).get("id", "")
                if sid.lower() == lnet_id.lower():
                    names.append(n["name"])
        print(json.dumps(sorted(set(names))))
    elif cmd == "nic-ip":
        rg, name = a
        r = find(rg, "nic", name)
        ip = None
        if r:
            for ipc in ((show(r["id"]) or {}).get("properties") or {}).get("ipConfigurations") or []:
                pr = ipc.get("properties") or {}
                ip = pr.get("privateIPAddress") or pr.get("privateIpAddress") or ip
        print(ip or "pending")
    elif cmd == "image-os":
        rg, name = a
        r = find(rg, "image", name)
        if not r:
            sys.stderr.write(f"image '{name}' not found\n")
            return 2
        os_type = ((show(r["id"]) or {}).get("properties") or {}).get("osType") or "Windows"
        print("Linux" if os_type.lower() == "linux" else "Windows")
    elif cmd == "params":
        (outfile,) = a
        values = json.load(sys.stdin)
        doc = {
            "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
            "contentVersion": "1.0.0.0",
            "parameters": {k: {"value": v} for k, v in values.items()},
        }
        with open(outfile, "w") as f:
            json.dump(doc, f)
    else:
        sys.stderr.write(f"unknown command {cmd}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
