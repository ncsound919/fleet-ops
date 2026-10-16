#!/usr/bin/env bash
# fleet-ops notify hook -> Telegram.
#
# ecosystem-watch.sh calls `$(dirname STATE_DIR)/notify.sh <report>` when that
# file exists and is executable; cloned to ~/fleet-ops that is this file. It
# pushes the nightly report to the operator's phone, which is where the operator
# will be once the laptop is gone.
#
# Env (or ~/.fleet-ops.env): TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID.
# The token is never printed. A delivery failure exits non-zero; the caller
# already tolerates that and still writes the report.
#
# Usage: ./notify.sh /home/USER/fleet-ops/watch/2026-10-16.md

set -euo pipefail

if [ -f "$HOME/.fleet-ops.env" ]; then set -a; . "$HOME/.fleet-ops.env"; set +a; fi

REPORT="${1:?usage: notify.sh <report-path>}"
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set (see ~/.fleet-ops.env)}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID not set (see ~/.fleet-ops.env)}"

[ -f "$REPORT" ] || { echo "notify: report not found: $REPORT" >&2; exit 1; }
command -v jq  >/dev/null || { echo "notify: jq not installed"   >&2; exit 127; }
command -v curl >/dev/null || { echo "notify: curl not installed" >&2; exit 127; }

# Telegram hard-caps one message at 4096 chars; leave room for the header.
body="$(head -c 3500 "$REPORT")"
text="fleet-ops: $(basename "$REPORT")
$body"

payload="$(jq -n --arg chat "$TELEGRAM_CHAT_ID" --arg text "$text" \
  '{chat_id:$chat, text:$text, disable_web_page_preview:true}')"

out="$(mktemp)"
code="$(curl -sS -o "$out" -w '%{http_code}' \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H 'content-type: application/json' -d "$payload" || echo 000)"

if [ "$code" != "200" ]; then
  echo "notify: telegram sendMessage HTTP $code: $(jq -r '.description // "unparseable response"' "$out" 2>/dev/null || echo 'no body')" >&2
  rm -f "$out"
  exit 1
fi
rm -f "$out"
echo "notify: sent $(basename "$REPORT") ($(wc -c <"$REPORT") bytes) to telegram"
