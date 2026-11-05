#!/usr/bin/env python3
"""Rewrite the auto-filled dropdown lists in pipelines/*.yml.

Azure Pipelines runtime-parameter dropdowns are static YAML, so this script refreshes them from what
actually exists in Azure. A list is marked like this in a pipeline file:

      values:
        - (none)                      # static entries outside the markers are kept
        # AUTO:nsgs:BEGIN
        - nsg-infra
        # AUTO:nsgs:END

and the parameter's default line can carry   # AUTO:nsgs   so it is kept valid.

Usage: sync_dropdowns.py <lists.json> <file> [<file> ...]
  lists.json = {"lnets": [...], "nsgs": [...], "images": [...], "hostpools": [...]}
Prints a summary; exit 0 whether or not anything changed.
"""
import json
import re
import sys

BEGIN = re.compile(r"^(?P<indent>\s*)# AUTO:(?P<key>\w+):BEGIN\s*$")
DEFAULT = re.compile(r"^(?P<pre>\s*default:\s*)(?P<val>.*?)(?P<post>\s*# AUTO:(?P<key>\w+)\s*)$")
ITEM = re.compile(r"^\s*-\s*(?P<val>.+?)\s*$")


def yaml_scalar(v):
    # quote anything YAML might misread (leading '(' is fine, but keep it simple and safe)
    return v if re.fullmatch(r"[A-Za-z0-9_.()\-]+", v) and v.lower() not in ("true", "false", "null", "yes", "no") else json.dumps(v)


def sync_file(path, lists):
    lines = open(path, encoding="utf-8").read().splitlines()
    out, i, changed = [], 0, []
    # first pass: replace AUTO blocks, remember resulting value lists per key (including static items)
    while i < len(lines):
        m = BEGIN.match(lines[i])
        if not m or m.group("key") not in lists:
            out.append(lines[i]); i += 1; continue
        key, indent = m.group("key"), m.group("indent")
        j = i + 1
        while j < len(lines) and not lines[j].strip().startswith(f"# AUTO:{key}:END"):
            j += 1
        if j >= len(lines):
            raise SystemExit(f"{path}: AUTO:{key}:BEGIN without END")
        old = [ITEM.match(l).group("val") for l in lines[i + 1:j] if ITEM.match(l)]
        # static entries like "(none)" / "(new)" right above the block mean an empty list is fine
        k = len(out) - 1
        while k >= 0 and not out[k].strip().startswith("values:"):
            k -= 1
        has_static = any(ITEM.match(l) for l in out[k + 1:]) if k >= 0 else False
        new = lists[key] or ([] if has_static else ["(none found)"])
        out.append(lines[i])
        out += [f"{indent}- {yaml_scalar(v)}" for v in new]
        out.append(lines[j])
        if [o.strip('"') for o in old] != new:
            changed.append(f"{key}: {old} -> {new}")
        i = j + 1

    # second pass: make sure AUTO defaults are still in their list
    result = []
    for line in out:
        m = DEFAULT.match(line)
        if m and m.group("key") in lists:
            cur = m.group("val").strip().strip('"')
            options = lists[m.group("key")] or ["(none found)"]
            if cur not in options and not cur.startswith("("):
                line = f"{m.group('pre')}{yaml_scalar(options[0])}{m.group('post')}"
                changed.append(f"default {m.group('key')}: {cur} -> {options[0]}")
        result.append(line)

    if changed:
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(result) + "\n")
    return changed


def main():
    lists = json.load(open(sys.argv[1]))
    total = 0
    for path in sys.argv[2:]:
        ch = sync_file(path, lists)
        total += len(ch)
        for c in ch:
            print(f"{path}: {c}")
    if not total:
        print("Dropdowns already up to date.")


if __name__ == "__main__":
    main()
