#!/usr/bin/env bash
# Install the box-side watch cron entries (idempotent).
#
# Adds:
#   17 9 * * *   ecosystem-watch.sh   (nightly API sweep)
#    0 10 * * 0  ecosystem-sweep.sh   (weekly full sweep)
#
# Re-running is safe: entries are matched by script name and replaced.
# Usage: ./install-cron.sh         (preview)
#        ./install-cron.sh --apply (write crontab)

set -euo pipefail
BOX_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCH="$BOX_DIR/ecosystem-watch.sh"
SWEEP="$BOX_DIR/ecosystem-sweep.sh"
LOG="$HOME/fleet-ops/watch/cron.log"

chmod +x "$WATCH" "$SWEEP" 2>/dev/null || true
mkdir -p "$HOME/fleet-ops/watch"

line_watch="17 9 * * * ORG=\${ORG:-ncsound919} \"$WATCH\" >> \"$LOG\" 2>&1"
line_sweep="0 10 * * 0 ORG=\${ORG:-ncsound919} \"$SWEEP\" >> \"$LOG\" 2>&1"

current="$(crontab -l 2>/dev/null || true)"
# strip any prior lines for these scripts
kept="$(printf '%s\n' "$current" | grep -v 'ecosystem-watch.sh' | grep -v 'ecosystem-sweep.sh' || true)"
new="$(printf '%s\n%s\n%s\n' "$kept" "$line_watch" "$line_sweep" | sed '/^$/d')"

if [ "${1:-}" != "--apply" ]; then
  echo "--- crontab that WOULD be installed ---"
  printf '%s\n' "$new"
  echo "--- re-run with --apply to install ---"
  exit 0
fi

printf '%s\n' "$new" | crontab -
echo "installed:"; crontab -l | grep -E 'ecosystem-(watch|sweep)\.sh'
