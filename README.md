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

## Building

Prerequisites: Xcode 26+, [`xcodegen`](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). Optional for benchmarks: `brew install hyperfine`.

```sh
make build      # xcodegen generate + xcodebuild (Release)
make run        # launch the app
make test       # engine unit tests (headless, no app build)
make bench      # cold-launch benchmark against the corpus
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
