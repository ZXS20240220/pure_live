"""Union-merge conflicted translation JSON files during cherry-pick.

Usage: python tool/resolve_translation_union.py

For assets/translations/en.json and zh.json that are in unmerged (UU) state,
take stage-2 (ours/dev), stage-3 (theirs/upstream), stage-1 (base), run
`git merge-file --union`, then repair the doubled closing brace that appears
when dev's file tail is followed by upstream's appended keys. Finally validate
JSON syntax and detect duplicate keys (removing the trailing duplicate entry
when both occurrences are byte-identical).
"""

import collections
import json
import os
import subprocess
import sys

FILES = ["assets/translations/en.json", "assets/translations/zh.json"]
TEMP = os.environ.get("TEMP", os.environ.get("TMP", "/tmp"))


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, check=True, **kw)


def union_merge(path: str) -> str:
    stem = os.path.basename(path).split(".")[0]
    ours = os.path.join(TEMP, f"{stem}_ours.json")
    theirs = os.path.join(TEMP, f"{stem}_theirs.json")
    base = os.path.join(TEMP, f"{stem}_base.json")
    for stage, out in ((2, ours), (3, theirs), (1, base)):
        content = run(["git", "show", f":{stage}:{path}"], cwd=os.getcwd()).stdout.decode("utf-8")
        with open(out, "w", encoding="utf-8", newline="") as f:
            f.write(content)
    r = subprocess.run(["git", "merge-file", "--union", ours, base, theirs], capture_output=True)
    if r.returncode not in (0,):
        print(f"{path}: merge-file exit {r.returncode}", file=sys.stderr)
        sys.exit(1)
    return open(ours, encoding="utf-8").read()


def fix_double_brace(text: str) -> str:
    marker = '"\n}\n  "'
    idx = text.find(marker)
    if idx != -1:
        text = text[:idx] + '",\n  "' + text[idx + len(marker):]
    return text


def dedupe(text: str) -> str:
    """Remove duplicate top-level key entries; keep dev's (first) value.

    Returns (text, conflicts). A conflict is the same key carrying DIFFERENT
    values on the two sides — those are reported, not silently merged.
    """
    lines = text.splitlines(keepends=True)
    seen = {}
    conflicts = []
    out = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('"') and '":' in stripped:
            key, _, value = stripped.partition('":')
            normalized = key + '"' + ":" + value.rstrip().rstrip(",")
            if normalized in seen:
                continue  # identical key+value duplicate, drop
            if key + '"' in seen:
                conflicts.append(key + '"')
                continue  # different value for same key: keep first (dev), report
            seen[key + '"'] = normalized
        out.append(line)
    text = "".join(out)
    # Repair any trailing comma directly before the closing brace.
    text = text.replace(",\n}", "\n}")
    return text, conflicts


def validate(text: str, path: str) -> None:
    if "<<<<<<<" in text or ">>>>>>>" in text:
        print(f"{path}: conflict markers remain", file=sys.stderr)
        sys.exit(1)
    dups = []

    def hook(pairs):
        seen = collections.Counter(k for k, _ in pairs)
        dups.extend(k for k, c in seen.items() if c > 1)
        return dict(pairs)

    json.loads(text, object_pairs_hook=hook)
    if dups:
        print(f"{path}: duplicate keys {dups[:10]}", file=sys.stderr)
        sys.exit(1)


for path in FILES:
    text = union_merge(path)
    text = fix_double_brace(text)
    text, conflicts = dedupe(text)
    validate(text, path)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    print(f"{path}: OK" + (f" (value conflicts, dev kept: {conflicts})" if conflicts else ""))
