#!/bin/zsh
# Build and install 耳语同传 into /Applications, and put `hushpiece` on PATH.
exec "$(dirname "$0")/build-app.sh" --install
