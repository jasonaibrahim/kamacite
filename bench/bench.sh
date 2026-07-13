#!/bin/bash
# Cold-launch benchmark: runs the app with --bench N times per corpus file and reports
# in-app phase timings (VWPERF JSON lines from stderr). If hyperfine is installed, it
# adds an external wall-time cross-check.
#
# "Cold" here = fresh process; the dyld shared cache and file cache stay warm. True
# cold start needs `sudo purge` between runs (VW_BENCH_PURGE=1) or a reboot.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: bench.sh path/to/Kamacite.app [runs]}"
RUNS="${2:-10}"
BIN="$APP/Contents/MacOS/Kamacite"
[[ -x "$BIN" ]] || { echo "error: $BIN not found (make build first)" >&2; exit 1; }

SHA="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
OUT="bench/results/$SHA.jsonl"
mkdir -p bench/results
: > "$OUT"

run_case() {
  local label="$1"; shift
  echo "→ $label × $RUNS"
  for ((i = 0; i < RUNS; i++)); do
    [[ "${VW_BENCH_PURGE:-0}" == "1" ]] && sudo purge
    "$BIN" --bench "$@" 2>&1 | sed -n 's/^VWPERF //p' >> "$OUT"
  done
}

run_case "blank window (shell baseline)"
for f in bench/corpus/small.md bench/corpus/typical-llm.md bench/corpus/large.md; do
  if [[ -f "$f" ]]; then
    run_case "$f" "$f"
  else
    echo "skip: $f (generate with bench/gen_corpus.py)"
  fi
done

echo
python3 bench/report.py "$OUT"

if command -v hyperfine >/dev/null 2>&1; then
  echo
  echo "hyperfine wall-time cross-check (typical-llm.md):"
  hyperfine --warmup 2 --runs "$RUNS" "$BIN --bench bench/corpus/typical-llm.md"
else
  echo
  echo "note: install hyperfine (brew install hyperfine) for a wall-time cross-check"
fi
