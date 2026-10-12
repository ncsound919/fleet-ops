#!/usr/bin/env bash
# Ecosystem Watch - box-side nightly sweep. No GitHub Actions dependency: this
# runs on the always-on host (Oracle ARM / Hetzner) from cron.
#
# Why this exists: GitHub Actions is blocked account-wide (0-step setup
# failures, no runner), so the clock cannot live there. This script does the
# same API-only signal collection and writes a local report.
#
# Requires: gh (authed via GH_TOKEN or `gh auth login`), jq.
# Fail-closed: zero repos resolved exits non-zero rather than writing a
# vacuous "all good" report.
#
# Usage:  ORG=ncsound919 ./ecosystem-watch.sh
# Cron:   17 9 * * *  /home/USER/fleet-ops/box/ecosystem-watch.sh >> /home/USER/fleet-ops/watch/cron.log 2>&1

set -euo pipefail

ORG="${ORG:-ncsound919}"
STATE_DIR="${STATE_DIR:-$HOME/fleet-ops/watch}"
STAMP="$(date -u +%Y-%m-%d)"
OUT="$STATE_DIR/$STAMP.md"

command -v gh >/dev/null || { echo "ecosystem-watch: gh not installed" >&2; exit 127; }
command -v jq >/dev/null || { echo "ecosystem-watch: jq not installed" >&2; exit 127; }
mkdir -p "$STATE_DIR"

# Enumerate owned, non-fork, non-archived repos.
repos_json="$(gh repo list "$ORG" --limit 300 --json name,isFork,isArchived \
  --jq '[.[]|select((.isFork|not) and (.isArchived|not))|.name]')"
n="$(jq 'length' <<<"$repos_json")"
if [ "${n:-0}" -le 0 ]; then
  echo "ecosystem-watch: no repos resolved for $ORG - refusing a vacuous report" >&2
  exit 1
fi

tmp="$(mktemp)"
{
  echo "# Ecosystem Watch - $STAMP"
  echo
  echo "checked $n repositories (owner $ORG)"
  echo
  echo "| repo | priv | dep | secret | stale(d) | last run | PRs |"
  echo "|---|---|---|---|---|---|---|"
} > "$tmp"

for r in $(jq -r '.[]' <<<"$repos_json"); do
  priv="$(gh api "repos/$ORG/$r" --jq '.private' 2>/dev/null || echo '?')"
  pushed="$(gh api "repos/$ORG/$r" --jq '.pushed_at' 2>/dev/null || echo '')"
  if [ -n "$pushed" ]; then
    days=$(( ( $(date +%s) - $(date -d "$pushed" +%s) ) / 86400 ))
  else
    days='?'
  fi
  dep="$(gh api "repos/$ORG/$r/dependabot/alerts?state=open&per_page=100" --jq 'length' 2>/dev/null || echo '?')"
  sec="$(gh api "repos/$ORG/$r/secret-scanning/alerts?state=open&per_page=100" --jq 'length' 2>/dev/null || echo '?')"
  run="$(gh run list -R "$ORG/$r" -L1 --json conclusion,status,workflowName \
    --jq '.[0] | "\(.workflowName):\(.conclusion // .status)"' 2>/dev/null || echo 'none')"
  prs="$(gh pr list -R "$ORG/$r" --state open --json number --jq 'length' 2>/dev/null || echo '?')"
  echo "| $r | $priv | $dep | $sec | $days | $run | $prs |" >> "$tmp"
done

mv "$tmp" "$OUT"
ln -sf "$OUT" "$STATE_DIR/latest.md"

# Optional hook: a notify.sh beside this STATE_DIR's parent, if present.
hook="$(dirname "$STATE_DIR")/notify.sh"
if [ -x "$hook" ]; then "$hook" "$OUT" || echo "ecosystem-watch: notify hook failed (report still written)"; fi

echo "ecosystem-watch: wrote $OUT ($n repos)"
