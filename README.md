# Kamacite

A native macOS markdown app built for one thing first: **the fastest markdown reading
experience ever built**. Markdown is increasingly what LLMs produce; Kamacite is the
native, instant way to read it — not an IDE, not Electron. Native AI editing is the
roadmap; speed is the foundation.

Kamacite is a nickel-iron metal that does not form on Earth — it arrives only inside
meteorites, and etching it reveals hidden lattice patterns in the metal. Obsidian cooled
in place; kamacite fell from the sky.

The document surface is a custom Metal renderer (CoreText shaping → glyph atlas → GPU
quads, the Zed/Ghostty architecture), written in Swift. Speed is the product: every
change is benchmarked, and regressions need justification.

## Performance budgets (process start → pixels on glass)

| Corpus | Cold | Warm (resident instance) |
|---|---|---|
| small.md (2KB) | < 400ms | < 100ms |
| typical-llm.md (50KB) | < 400ms | < 150ms |
| large.md (5MB) | < 700ms | < 400ms |
| huge.md (100MB) | < 2s to first viewport | post-v1 |

Plus: 120Hz scrolling; layout/GPU/atlas memory proportional to viewport, not document.

These budgets are machine-enforced. `make check` runs the unit tests plus a perf
gate (`bench/gate.py`) that holds cold first-pixel p50 per corpus and scroll-frame
p95 to the ceilings in `bench/baseline.json` — ceilings sit well below the product
budgets, at measured-on-this-machine numbers plus noise headroom, so a change that
merely *approaches* the budget still reads as the regression it is. Run it before
every PR. Raising a ceiling is allowed only as a deliberate trade: the same change
must append a justification entry to the baseline's `revisions` log (the gate
rejects raises without one), and review approves it.

## Building

Prerequisites: Xcode 26+, [`xcodegen`](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). Optional for benchmarks: `brew install hyperfine`.

```sh
make build      # xcodegen generate + xcodebuild (Release)
make run        # launch the app
make test       # engine unit tests (headless, no app build)
make bench      # cold-launch benchmark against the corpus
make check      # pre-PR suite: unit tests + perf regression gate (bench/baseline.json)
make install    # copy to /Applications and symlink the `kama` CLI onto PATH
make dev-link   # symlink the CLI against the build products (auto-updates per build)
```

## CLI

```sh
kama notes.md            # open in the app; reuses a running instance (the warm path)
kama --perf notes.md     # print launch/open phase timings to stderr (fresh launch)
kama --version
```

The `kama` binary lives inside `Kamacite.app/Contents/Helpers/` and is symlinked onto
PATH by `make install` / `make dev-link`.

## Live editing (the edit server)

The first half of native AI editing: the app runs a JSON-lines edit server on a unix
socket (`~/Library/Application Support/Kamacite/kama.sock`, `$KAMACITE_SOCKET` to
override). An agent sends edits — byte-range splices or uniqueness-checked
find/replace — which land in an **in-memory buffer** with the on-screen preview
updating live (bounded block-range reparse + height-preserving layout splice: only
the edited neighborhood re-derives, glass never moves). The file on disk changes only
on an explicit commit (atomic temp+rename), also reachable as ⌘S; the window carries
the standard edited dot and Commit/Discard/Cancel close prompt.

```sh
kama edit notes.md --old "## Status: draft" --new "## Status: final"
kama read notes.md --range 0:200 --raw       # buffer truth, not disk
kama edit notes.md --revision 3 --range 10:14 --text "new"   # optimistic CAS
kama commit notes.md                          # atomic write; kama discard reverts
kama status notes.md --hash                   # {revision, dirty, disk_changed, …}
kama debug-dump notes.md /tmp/frame.png       # offscreen render — agent eyes
```

Responses are one JSON line each (`{"ok":true,"result":{…}}` / structured error
codes: `non_unique_match`, `revision_mismatch`, `disk_changed`, …). Edits within one
request are atomic; `revision` increments per applied batch and is the CAS token.
The socket is also the single-instance rendezvous: a launching copy of the app that
finds it owned forwards its documents there and exits, so a dev build and an
installed build never accumulate parallel windows (bench instances are exempt).
`make smoke` drives the whole loop end to end; `make edit-bench` measures
edit→pixels latency (typical-llm.md p50 <1 ms; large.md p50 ~6 ms, 120Hz scroll holds
under a live edit storm).

## Layout

```
App/                 AppKit shell: lifecycle, windows, menus, perf plumbing
CLI/                 the `kama` command-line helper
Packages/VWEngine/   the engine: parse → style → layout → render → interaction
bench/               corpus + measurement harness (VWPERF JSON lines → p50/p95)
project.yml          source of truth for the Xcode project (generated, gitignored)
```

Engine target DAG: `VWCore → VWParse/VWStyle → VWText → VWLayout/VWRender →
VWInteraction → VWViewer`. (The `VW` prefix is a fossil from the project's working
name — kept because module prefixes are internal.) Everything below `VWViewer` is
AppKit-free and unit-tests headlessly. Source positions (UTF-8 byte spans) thread
through every stage — the anchor for editing and commenting.

## Perf philosophy

- `VW_PERF=1` prints a phase table (pre-main, open, read, parse, layout, present) after
  first present; `VW_PERF_JSON=1` emits machine-readable `VWPERF {...}` lines.
- `Kamacite --bench file.md` (the binary directly) opens, reports, and exits — the app
  itself is the benchmark subject, with no Launch Services noise.
- The blank-window baseline was recorded before any feature landed; `make bench` compares
  every change against the budgets above.
