#!/bin/zsh
# Build CallTrans and link the `calltrans` command into Homebrew's bin.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(brew --prefix)/bin/calltrans"
ln -sf "$PWD/.build/release/calltrans" "$BIN"
echo "installed: $BIN -> $PWD/.build/release/calltrans"
"$BIN" version
