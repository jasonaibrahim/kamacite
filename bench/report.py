#!/usr/bin/env python3
"""Summarize VWPERF JSON lines (one per app run) into per-phase p50/p95 tables."""
import json
import statistics
import sys
from collections import defaultdict


def p95(sorted_values):
    index = min(len(sorted_values) - 1, round(0.95 * (len(sorted_values) - 1)))
    return sorted_values[index]


def main(path):
    with open(path) as fh:
        rows = [json.loads(line) for line in fh if line.strip()]
    if not rows:
        sys.exit("no bench data collected — did the app emit VWPERF lines?")

    groups = defaultdict(list)
    for row in rows:
        groups[(row.get("file", "?"), row.get("mode", "?"))].append(row)

    for (name, mode), runs in groups.items():
        size = runs[0].get("bytes")
        suffix = f", {size / 1000:.0f} KB" if size else ""
        print(f"{name}  ({mode}, n={len(runs)}{suffix})")
        print(f"  {'phase':<16}{'p50 ms':>10}{'p95 ms':>10}")
        for key in runs[0]:
            if not key.endswith("_ms"):
                continue
            values = sorted(float(r[key]) for r in runs if key in r)
            if not values:
                continue
            print(f"  {key[:-3]:<16}{statistics.median(values):>10.1f}{p95(values):>10.1f}")
        print()


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else sys.exit("usage: report.py results.jsonl"))
