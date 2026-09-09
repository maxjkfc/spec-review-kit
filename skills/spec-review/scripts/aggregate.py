#!/usr/bin/env python3
"""Group cross-reviewer findings that touch overlapping code ranges.

This is deliberately conservative: it proposes duplicate candidates but never merges or drops a
finding. The main verifier makes the semantic decision.
"""

import argparse
import glob
import json
import os
import re
import sys

REF = re.compile(r"(?P<path>[A-Za-z0-9_./-]+\.[A-Za-z0-9]+):(?P<start>\d+)(?:-(?P<end>\d+))?")


def refs(value):
    found = []
    for match in REF.finditer(value or ""):
        start = int(match.group("start"))
        found.append({"path": match.group("path"), "start": start, "end": int(match.group("end") or start)})
    return found


def overlap(left, right):
    return any(
        a["path"] == b["path"] and a["start"] <= b["end"] and b["start"] <= a["end"]
        for a in left["refs"] for b in right["refs"]
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session_dir")
    parser.add_argument("--out", default=None)
    args = parser.parse_args()
    paths = sorted(glob.glob(os.path.join(args.session_dir, "*.findings.json")))
    if not paths:
        parser.error(f"no *.findings.json files in {args.session_dir}")

    findings = []
    ambiguities = []
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            result = json.load(handle)
        source = os.path.basename(path).removesuffix(".findings.json")
        for index, finding in enumerate(result.get("findings", [])):
            findings.append({"id": f"{source}:{index + 1}", "source": source, "refs": refs(finding.get("code_ref")), "finding": finding})
        for ambiguity in result.get("ambiguities", []):
            ambiguities.append({"source": source, "ambiguity": ambiguity})

    parent = list(range(len(findings)))
    def root(index):
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index
    def union(left, right):
        a, b = root(left), root(right)
        if a != b:
            parent[b] = a

    for left in range(len(findings)):
        for right in range(left + 1, len(findings)):
            if findings[left]["source"] != findings[right]["source"] and overlap(findings[left], findings[right]):
                union(left, right)

    buckets = {}
    for index, finding in enumerate(findings):
        buckets.setdefault(root(index), []).append(finding)
    groups = []
    for number, items in enumerate(buckets.values(), 1):
        groups.append({
            "group": number,
            "candidate_duplicate": len({item["source"] for item in items}) > 1,
            "items": items,
        })

    output = {"groups": groups, "ambiguities": ambiguities}
    destination = args.out or os.path.join(args.session_dir, "candidates.json")
    with open(destination, "w", encoding="utf-8") as handle:
        json.dump(output, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(destination)


if __name__ == "__main__":
    try:
        main()
    except (OSError, json.JSONDecodeError) as error:
        print(f"aggregate.py: {error}", file=sys.stderr)
        sys.exit(1)
