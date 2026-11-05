#!/usr/bin/env python3
"""Export a scrubbed copy of the repo for publishing publicly.

  export_public.py --map publish/scrub-map.json --out <dir>

- Copies every git-tracked file except the map's "exclude" list.
- Applies the map's literal replacements (longest first) to file contents and paths.
- Then refuses to finish (exit 1) if anything still looks identifying or secret:
    * any "leakTerms" value (case-insensitive)
    * any GUID not in "allowedGuids"
    * token / key patterns (Azure DevOps or GitHub PATs, private keys, storage keys, connection strings)
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

SECRET_PATTERNS = {
    "GitHub token": re.compile(r"\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"),
    "Azure DevOps PAT (52 char)": re.compile(r"(?<![A-Za-z0-9])[a-z2-7]{52}(?![A-Za-z0-9])"),
    "Azure DevOps PAT (84 char)": re.compile(r"(?<![A-Za-z0-9])[A-Za-z0-9]{76}AZDO[A-Za-z0-9]{4}(?![A-Za-z0-9])"),
    "Private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "Storage account key": re.compile(r"AccountKey=[A-Za-z0-9+/=]{20,}"),
    "Connection string secret": re.compile(r"(?i)(SharedAccessKey|Password)=[^;\s'\"$<]{6,}"),
    "JWT": re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
}
GUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def tracked_files(root):
    out = subprocess.check_output(["git", "-C", root, "ls-files", "-z"], text=True)
    return [f for f in out.split("\0") if f]


def scrub(text, repl):
    counts = {}
    for old, new in repl:
        n = text.count(old)
        if n:
            text = text.replace(old, new)
            counts[old] = n
    return text, counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--root", default=".")
    a = ap.parse_args()

    cfg = json.load(open(a.map, encoding="utf-8"))
    repl = sorted(cfg["replacements"], key=lambda r: -len(r[0]))
    exclude = set(cfg.get("exclude", []))
    allowed_guids = {g.lower() for g in cfg.get("allowedGuids", [])}
    leak_terms = [t.lower() for t in cfg.get("leakTerms", [])]

    if os.path.exists(a.out):
        shutil.rmtree(a.out)
    os.makedirs(a.out)

    totals, problems, copied = {}, [], 0
    for rel in tracked_files(a.root):
        if rel in exclude or rel.startswith("publish/"):
            continue
        src = os.path.join(a.root, rel)
        if not os.path.isfile(src):
            continue          # deleted in the working tree
        new_rel, _ = scrub(rel, repl)
        dst = os.path.join(a.out, new_rel)
        os.makedirs(os.path.dirname(dst) or a.out, exist_ok=True)
        raw = open(src, "rb").read()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            shutil.copyfile(src, dst)
            problems.append(f"{rel}: binary file copied unscrubbed - review it by hand")
            continue
        text, counts = scrub(text, repl)
        if rel == "README.md" and cfg.get("readmeBanner"):
            first, _, rest = text.partition("\n")
            text = f"{first}\n\n{cfg['readmeBanner']}{rest}"
        for k, v in counts.items():
            totals[k] = totals.get(k, 0) + v
        with open(dst, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        copied += 1

        # ---- leak checks on the scrubbed content ----
        low = text.lower() + "\n" + new_rel.lower()
        for t in leak_terms:
            if t in low:
                problems.append(f"{new_rel}: still contains '{t}'")
        for g in set(m.lower() for m in GUID.findall(text)):
            if g not in allowed_guids:
                problems.append(f"{new_rel}: unrecognised GUID {g} (add to replacements, or to allowedGuids if it's a public constant)")
        for label, rx in SECRET_PATTERNS.items():
            if rx.search(text):
                problems.append(f"{new_rel}: looks like a {label}")

    print(f"Exported {copied} files to {a.out}")
    print("Replacements made:")
    for old, new in repl:
        print(f"  {totals.get(old, 0):4d} x  {old[:12]}...  ->  {new}" if len(old) > 15 else f"  {totals.get(old, 0):4d} x  {old}  ->  {new}")
    if problems:
        print("\nNOT SAFE TO PUBLISH:")
        for p in problems:
            print("  - " + p)
        sys.exit(1)
    print("\nLeak check passed: no identifying values, unknown GUIDs or secrets found.")


if __name__ == "__main__":
    main()
