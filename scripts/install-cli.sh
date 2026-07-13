#!/bin/bash
# Symlink the kama CLI (inside Kamacite.app) into a PATH directory.
set -euo pipefail

APP="${1:-/Applications/Kamacite.app}"
HELPER="$APP/Contents/Helpers/kama"
[[ -x "$HELPER" ]] || { echo "error: $HELPER not found (build the app first)" >&2; exit 1; }

for BIN in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  if [[ -d "$BIN" && -w "$BIN" ]]; then
    ln -sf "$HELPER" "$BIN/kama"
    echo "linked $BIN/kama → $HELPER"
    case ":$PATH:" in
      *":$BIN:"*) ;;
      *) echo "note: $BIN is not on your PATH" ;;
    esac
    exit 0
  fi
done

echo "error: no writable bin dir (tried /opt/homebrew/bin, /usr/local/bin, ~/.local/bin)" >&2
exit 1
