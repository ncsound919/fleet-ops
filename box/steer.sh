#!/usr/bin/env bash
# fleet-ops steer - the phone -> box control lane.
#
# Long-polls Telegram getUpdates and runs a FIXED, allowlisted verb table.
# There is no free-form shell: the case statement below is the entire surface.
# Only messages from STEER_CHAT_ID are honoured; every other chat is ignored
# and logged. This is the "steer from a phone" lane the zero-laptop setup needs
# before any native app exists.
#
# Env (or ~/.fleet-ops.env): TELEGRAM_BOT_TOKEN, STEER_CHAT_ID.
# Run under systemd (or nohup). One poller per bot token - a second getUpdates
# consumer steals the offset.
#
# Verbs: /status /watch /sweep /repos /help
#
# Usage: STEER_CHAT_ID=123456789 ./steer.sh

set -uo pipefail

if [ -f "$HOME/.fleet-ops.env" ]; then set -a; . "$HOME/.fleet-ops.env"; set +a; fi

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set (see ~/.fleet-ops.env)}"
: "${STEER_CHAT_ID:?STEER_CHAT_ID not set - refusing to run with no allowlist}"

ORG="${ORG:-ncsound919}"
STATE_DIR="${STATE_DIR:-$HOME/fleet-ops/watch}"
BOX_DIR="$(cd "$(dirname "$0")" && pwd)"
OFFSET_FILE="$STATE_DIR/steer-offset"
LOG="$STATE_DIR/steer.log"
API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

command -v jq   >/dev/null || { echo "steer: jq not installed"   >&2; exit 127; }
command -v curl >/dev/null || { echo "steer: curl not installed" >&2; exit 127; }
command -v gh   >/dev/null || { echo "steer: gh not installed"   >&2; exit 127; }
mkdir -p "$STATE_DIR"
offset="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"

log() { echo "$(date -u +%FT%TZ) $*" >>"$LOG"; }

send() { # send <text>
  local payload
  payload="$(jq -n --arg chat "$STEER_CHAT_ID" --arg text "$1" \
    '{chat_id:$chat, text:$text, disable_web_page_preview:true}')"
  curl -sS -o /dev/null "$API/sendMessage" \
    -H 'content-type: application/json' -d "$payload" || true
}

run_verb() { # run_verb <command-text> ; prints the reply
  case "$1" in
    /help|/start)
      printf '%s\n' "fleet-ops steer - verbs:" \
        "/status - host uptime + the latest report" \
        "/watch  - run the nightly API sweep now" \
        "/sweep  - run the weekly full sweep now (takes minutes)" \
        "/repos  - list watched repos" ;;
    /status)
      echo "host: $(hostname) - up $(uptime -p 2>/dev/null || uptime)"
      echo "report: $(readlink -f "$STATE_DIR/latest.md" 2>/dev/null || echo none)"
      echo
      head -c 3000 "$STATE_DIR/latest.md" 2>/dev/null || echo "(no report yet - send /watch)" ;;
    /watch)
      if ORG="$ORG" "$BOX_DIR/ecosystem-watch.sh" >/dev/null 2>&1; then
        head -c 3000 "$STATE_DIR/latest.md"
      else
        echo "watch FAILED - see $LOG"
      fi ;;
    /sweep)
      if ORG="$ORG" "$BOX_DIR/ecosystem-sweep.sh" >/dev/null 2>&1; then
        head -c 3000 "$STATE_DIR/latest-sweep.md"
      else
        echo "sweep FAILED - see $LOG"
      fi ;;
    /repos)
      gh repo list "$ORG" --limit 300 --json name,isFork,isArchived \
        --jq '[.[]|select((.isFork|not) and (.isArchived|not))|.name] | join(", ")' ;;
    *)
      echo "unknown command - send /help" ;;
  esac
}

log "steer: started (org=$ORG chat=$STEER_CHAT_ID offset=$offset)"
echo "steer: listening (org=$ORG, chat=$STEER_CHAT_ID)"
while :; do
  updates="$(curl -sS "$API/getUpdates?timeout=50&offset=$offset" 2>/dev/null)" || { sleep 5; continue; }
  count="$(jq -r '.result | length' <<<"$updates" 2>/dev/null || echo 0)"
  [ "${count:-0}" -gt 0 ] || continue
  while IFS= read -r u; do
    offset="$(( $(jq -r '.update_id' <<<"$u") + 1 ))"
    echo "$offset" >"$OFFSET_FILE"
    chat="$(jq -r '.message.chat.id // empty' <<<"$u")"
    text="$(jq -r '.message.text // empty' <<<"$u")"
    [ -n "$text" ] || continue
    if [ "$chat" != "$STEER_CHAT_ID" ]; then log "ignored chat $chat: $text"; continue; fi
    log "verb $text"
    reply="$(run_verb "$text" 2>&1 | head -c 3500)"
    send "$reply"
  done < <(jq -c '.result[]' <<<"$updates")
done
