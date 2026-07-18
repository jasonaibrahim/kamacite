#!/usr/bin/env python3
"""Perf regression gate — the machine-checked half of bench/baseline.json.

Runs the cold-launch bench (bench.sh) and the in-app scroll bench against the
built app, then holds every metric under baseline.json's `gates` to its
ceiling (the regression bar) and budget (the absolute product budget).
Exits nonzero on any breach.

The ceilings themselves are guarded: if this change raises any ceiling
relative to the committed baseline (git HEAD) without appending a new entry
to `revisions`, the gate fails before benching — a raise must arrive with
documented justification, approved in review.

usage: gate.py path/to/Kamacite.app [runs]
"""
import json
import os
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, "bench", "baseline.json")

POLICY_REMINDER = """\
Perf gate policy (bench/baseline.json):
  A failed ceiling is a regression. Either fix the regression, or — if the
  cost is a deliberate trade — raise the ceiling in bench/baseline.json AND
  append a `revisions` entry (date, reason, what moved and why it is worth
  it) in the same change, to be approved in review. The gate rejects raises
  that arrive without one. If the machine was busy (builds, agent fleets),
  re-run on a quiet machine before concluding anything."""


def collect_ceilings(node, path=""):
    """Flatten `gates` into {path: ceiling}; any dict with a `ceiling` key is a gate."""
    out = {}
    if isinstance(node, dict):
        if "ceiling" in node:
            out[path] = float(node["ceiling"])
        else:
            for key, value in node.items():
                out.update(collect_ceilings(value, f"{path}/{key}" if path else key))
    return out


def audit_ceiling_raises(current):
    """A ceiling raise vs the committed baseline requires a new revisions entry."""
    show = subprocess.run(
        ["git", "show", "HEAD:bench/baseline.json"],
        capture_output=True, text=True, cwd=ROOT,
    )
    if show.returncode != 0:
        return  # no committed baseline yet
    try:
        previous = json.loads(show.stdout)
    except json.JSONDecodeError:
        return
    if "gates" not in previous:
        return  # pre-gate schema; nothing to audit against
    old = collect_ceilings(previous["gates"])
    new = collect_ceilings(current["gates"])
    raised = [
        f"  {path}: {old[path]:g} -> {new[path]:g}"
        for path in sorted(new)
        if path in old and new[path] > old[path]
    ]
    if raised and len(current.get("revisions", [])) <= len(previous.get("revisions", [])):
        sys.exit(
            "GATE FAIL: ceiling(s) raised without a new bench/baseline.json "
            "revisions entry:\n" + "\n".join(raised) + "\n\n" + POLICY_REMINDER
        )


def run_cold_bench(app, runs):
    subprocess.run([os.path.join(ROOT, "bench", "bench.sh"), app, runs],
                   cwd=ROOT, check=True)
    sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                         capture_output=True, text=True, cwd=ROOT).stdout.strip() or "dev"
    results = os.path.join(ROOT, "bench", "results", f"{sha}.jsonl")
    p50s = {}
    with open(results) as fh:
        rows = [json.loads(line) for line in fh if line.strip()]
    for name in {row.get("file", "?") for row in rows}:
        values = [float(r["first_pixel_ms"]) for r in rows
                  if r.get("file") == name and "first_pixel_ms" in r]
        if values:
            p50s[name] = statistics.median(values)
    return p50s


def run_scroll_bench(app):
    """480 serialized frames over large.md; the app itself exits 2 past 8.33ms p95."""
    env = dict(os.environ, VW_SCROLL_BENCH="1")
    result = subprocess.run(
        [os.path.join(app, "Contents", "MacOS", "Kamacite"),
         "--bench", "bench/corpus/large.md"],
        capture_output=True, text=True, cwd=ROOT, env=env, timeout=120,
    )
    for line in result.stderr.splitlines():
        if line.startswith("VWSCROLL "):
            return float(json.loads(line[len("VWSCROLL "):])["p95_ms"])
    sys.exit(f"GATE FAIL: scroll bench emitted no VWSCROLL line "
             f"(exit {result.returncode}):\n{result.stderr[-2000:]}")


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: gate.py path/to/Kamacite.app [runs]")
    app, runs = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "10")
    with open(BASELINE) as fh:
        baseline = json.load(fh)
    gates = baseline["gates"]

    audit_ceiling_raises(baseline)

    large = os.path.join(ROOT, "bench", "corpus", "large.md")
    if not os.path.exists(large):
        subprocess.run([sys.executable, "bench/gen_corpus.py", "large"],
                       cwd=ROOT, check=True)

    p50s = run_cold_bench(app, runs)
    scroll_p95 = run_scroll_bench(app)

    failures = []
    print("perf gate  (ceiling = regression bar; budget = product budget)")
    for corpus, gate in gates["cold_first_pixel_p50_ms"].items():
        measured = p50s.get(corpus)
        if measured is None:
            failures.append(f"{corpus}: no bench data (corpus file missing?)")
            print(f"  FAIL  cold first_pixel p50  {corpus:<16} — no data")
            continue
        ceiling, budget = float(gate["ceiling"]), gate.get("budget")
        over = measured > ceiling or (budget is not None and measured > budget)
        verdict = "FAIL" if over else "ok  "
        cap = f"ceiling {ceiling:g}" + (f", budget {budget:g}" if budget else "")
        print(f"  {verdict}  cold first_pixel p50  {corpus:<16} {measured:7.1f} ms  ({cap})")
        if over:
            failures.append(f"cold first_pixel p50 {corpus}: {measured:.1f}ms > {cap}")
    scroll_ceiling = float(gates["scroll_frame_p95_ms"]["ceiling"])
    verdict = "FAIL" if scroll_p95 > scroll_ceiling else "ok  "
    print(f"  {verdict}  scroll frame p95      {'large.md':<16} {scroll_p95:7.2f} ms  (ceiling {scroll_ceiling:g})")
    if scroll_p95 > scroll_ceiling:
        failures.append(f"scroll frame p95: {scroll_p95:.2f}ms > {scroll_ceiling}")

    if failures:
        print(f"\nGATE FAIL ({len(failures)}):")
        for failure in failures:
            print(f"  - {failure}")
        print("\n" + POLICY_REMINDER)
        sys.exit(1)
    print("\nperf gate: PASS")


if __name__ == "__main__":
    main()
