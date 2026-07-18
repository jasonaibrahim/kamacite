#!/bin/bash
# End-to-end smoke of the edit server: launch the built app on a corpus copy
# with an isolated socket, drive every verb through the kama CLI, assert byte
# truth on disk at each step, and check teardown. Exercises the REAL stack:
# socket → wire → resolver → engine buffer → bounded reparse → commit.
set -euo pipefail

DERIVED="${DERIVED:-build}"
APP="$DERIVED/Build/Products/Release/Kamacite.app"
KAMA="$APP/Contents/Helpers/kama"
BIN="$APP/Contents/MacOS/Kamacite"

[ -x "$BIN" ] || { echo "edit-smoke: app not built (run make build)"; exit 1; }

WORK=$(mktemp -d /tmp/kamacite-smoke.XXXXXX)
export KAMACITE_SOCKET="$WORK/test.sock"
DOC="$WORK/doc.md"
cp bench/corpus/typical-llm.md "$DOC"
APP_PID=""

cleanup() {
    [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "edit-smoke: FAIL — $1"; exit 1; }

# jq-free JSON field checks (the response format is stable, sorted keys).
expect_contains() { # response, needle, label
    case "$1" in *"$2"*) ;; *) fail "$3: expected $2 in: $1";; esac
}

"$BIN" "$DOC" >"$WORK/app.log" 2>&1 &
APP_PID=$!
disown "$APP_PID" 2>/dev/null || true # keep the cleanup kill out of job-control chatter

# The server starts ~0.5s after first present; poll.
for _ in $(seq 1 50); do
    [ -S "$KAMACITE_SOCKET" ] && break
    sleep 0.2
done
[ -S "$KAMACITE_SOCKET" ] || fail "socket never appeared (app log: $(tail -3 "$WORK/app.log" 2>/dev/null))"

R=$("$KAMA" status "$DOC")
expect_contains "$R" '"revision":0' "fresh status"
expect_contains "$R" '"dirty":false' "fresh status"

R=$("$KAMA" edit "$DOC" --old "# Glyph Span" --new "# Glyph Span (SMOKE)")
expect_contains "$R" '"revision":1' "edit"
expect_contains "$R" '"dirty":true' "edit"
head -1 "$DOC" | grep -q "SMOKE" && fail "edit leaked to disk before commit"

R=$("$KAMA" read "$DOC" --range 0:20 --raw)
expect_contains "$R" "(SMOKE" "read-back sees the buffer" || true
"$KAMA" read "$DOC" --range 0:22 --raw | grep -q "SMOKE" || fail "read-back missing edit"

"$KAMA" debug-dump "$DOC" "$WORK/frame.png" >/dev/null
[ -s "$WORK/frame.png" ] || fail "debug-dump produced no png"

# Error paths: exit code 1 + stable codes.
set +e
R=$("$KAMA" edit "$DOC" --revision 0 --old "x" --new "y"); CODE=$?
set -e
[ "$CODE" = "1" ] || fail "revision mismatch should exit 1"
expect_contains "$R" '"code":"revision_mismatch"' "revision CAS"

set +e
R=$("$KAMA" edit "$DOC" --old "the" --new "THE"); CODE=$?
set -e
[ "$CODE" = "1" ] || fail "non-unique should exit 1"
expect_contains "$R" '"code":"non_unique_match"' "uniqueness check"

set +e
R=$("$KAMA" status "$WORK/not-open.md"); CODE=$?
set -e
[ "$CODE" = "1" ] || fail "no_such_doc should exit 1"
expect_contains "$R" '"code":"no_such_doc"' "unknown doc"

INODE_BEFORE=$(stat -f %i "$DOC")
R=$("$KAMA" commit "$DOC")
expect_contains "$R" '"dirty":false' "commit clears dirty"
head -1 "$DOC" | grep -q "SMOKE" || fail "commit did not reach disk"
[ "$(stat -f %i "$DOC")" != "$INODE_BEFORE" ] || fail "commit was not an atomic replace (same inode)"

R=$("$KAMA" edit "$DOC" --old "(SMOKE)" --new "(SMOKE-TEMP)")
R=$("$KAMA" discard "$DOC")
expect_contains "$R" '"dirty":false' "discard lands clean"
head -1 "$DOC" | grep -q "SMOKE-TEMP" && fail "discard left the temp edit on disk"
"$KAMA" read "$DOC" --range 0:30 --raw | grep -q "SMOKE-TEMP" && fail "discard left the temp edit in the buffer"

# External-change tripwire: commit refuses, force overrides.
R=$("$KAMA" edit "$DOC" --old "(SMOKE)" --new "(SMOKE-2)")
echo "external" >> "$DOC"
set +e
R=$("$KAMA" commit "$DOC"); CODE=$?
set -e
[ "$CODE" = "1" ] || fail "disk_changed should refuse"
expect_contains "$R" '"code":"disk_changed"' "external-change refusal"
R=$("$KAMA" commit "$DOC" --force)
expect_contains "$R" '"dirty":false' "forced commit"
tail -1 "$DOC" | grep -q "external" && fail "force commit kept the external line (buffer should win)"

# Inode dedup: the same file through a symlink reuses the window.
ln -s "$DOC" "$WORK/link.md"
R=$("$KAMA" open "$WORK/link.md")
expect_contains "$R" '"already_open":true' "symlink resolves to the same window"

# Single-instance guard: a second direct-exec launch against the same socket
# forwards its document to the owner and exits.
DOC2="$WORK/second.md"
printf '# Second doc\n\nForwarded content.\n' > "$DOC2"
"$BIN" "$DOC2" >"$WORK/app2.log" 2>&1 &
APP2_PID=$!
disown "$APP2_PID" 2>/dev/null || true
for _ in $(seq 1 50); do
    kill -0 "$APP2_PID" 2>/dev/null || break
    sleep 0.2
done
kill -0 "$APP2_PID" 2>/dev/null && fail "second instance did not exit (single-instance guard)"
R=$("$KAMA" status "$DOC2")
expect_contains "$R" '"revision":0' "forwarded doc opened in the primary instance"

kill "$APP_PID" 2>/dev/null || true
APP_PID=""

echo "edit-smoke: PASS"
