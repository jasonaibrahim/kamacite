#!/bin/bash
# Symlink the vw CLI (inside vw.app) into a PATH directory.
set -euo pipefail

APP="${1:-/Applications/vw.app}"
HELPER="$APP/Contents/Helpers/vw"
[[ -x "$HELPER" ]] || { echo "error: $HELPER not found (build the app first)" >&2; exit 1; }

for BIN in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  if [[ -d "$BIN" && -w "$BIN" ]]; then
    ln -sf "$HELPER" "$BIN/vw"
    echo "linked $BIN/vw → $HELPER"
    case ":$PATH:" in
      *":$BIN:"*) ;;
      *) echo "note: $BIN is not on your PATH" ;;
    esac
    exit 0
  fi
done

echo "error: no writable bin dir (tried /opt/homebrew/bin, /usr/local/bin, ~/.local/bin)" >&2
exit 1
