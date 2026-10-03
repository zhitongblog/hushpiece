# Source me: loads the team's App Store Connect API key (shared with the other projects).
# Override by exporting ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH yourself.
if [ -z "${ASC_KEY_ID:-}" ] && [ -f /Volumes/Dev/code/notebook/.env.local ]; then
  eval "$(grep -E '^(export )?(ASC_KEY_ID|ASC_ISSUER_ID|ASC_KEY_PATH)=' /Volumes/Dev/code/notebook/.env.local | sed 's/^export //; s/^/export /')"
fi
