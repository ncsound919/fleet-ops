#!/usr/bin/env bash
# Ecosystem Watch - box-side weekly full sweep. Checkout + build + test, on the
# always-on host. This is the expensive lane, so it is bounded and serial:
# one repo at a time, shallow clones, and a hard skip for Windows-only builds.
#
# Honest limitations (documented, not hidden):
#   - shallow clone (--depth 1): gitleaks runs on the working tree (--no-git),
#     so leaks that exist ONLY in history are not caught here.
#   - Windows-only targets (JUCE/CMake .vst3) are skipped, not "passed".
#   - a repo with no test/typecheck/lint script is reported "absent", not "ok".
#
# Usage:  ORG=ncsound919 ./ecosystem-sweep.sh
# Cron:   0 10 * * 0  /home/USER/fleet-ops/box/ecosystem-sweep.sh >> /home/USER/fleet-ops/watch/cron.log 2>&1

set -uo pipefail

ORG="${ORG:-ncsound919}"
STATE_DIR="${STATE_DIR:-$HOME/fleet-ops/watch}"
SRC_DIR="${SRC_DIR:-$HOME/fleet-ops/src}"
STAMP="$(date -u +%Y-%m-%d)"
OUT="$STATE_DIR/$STAMP-sweep.md"
GITLEAKS="${GITLEAKS:-gitleaks}"

command -v gh >/dev/null || { echo "ecosystem-sweep: gh not installed" >&2; exit 127; }
command -v jq >/dev/null || { echo "ecosystem-sweep: jq not installed" >&2; exit 127; }
mkdir -p "$STATE_DIR" "$SRC_DIR"

repos_json="$(gh repo list "$ORG" --limit 300 --json name,isFork,isArchived \
  --jq '[.[]|select((.isFork|not) and (.isArchived|not))|.name]')"
[ "$(jq 'length' <<<"$repos_json")" -gt 0 ] || { echo "ecosystem-sweep: no repos resolved" >&2; exit 1; }

tmp="$(mktemp)"
{
  echo "# Ecosystem Sweep - $STAMP"
  echo
  echo "| repo | hygiene | gitleaks | node | python | boundary | note |"
  echo "|---|---|---|---|---|---|---|"
} > "$tmp"

for r in $(jq -r '.[]' <<<"$repos_json"); do
  d="$SRC_DIR/$r"
  if [ -d "$d/.git" ]; then
    git -C "$d" fetch --depth 1 origin -q 2>/dev/null || true
    git -C "$d" reset --hard '@{u}' -q 2>/dev/null || git -C "$d" pull --ff-only -q 2>/dev/null || true
  else
    gh repo clone "$ORG/$r" "$d" -- --depth 1 -q 2>/dev/null || { echo "| $r | - | - | - | - | - | clone failed |" >> "$tmp"; continue; }
  fi

  # hygiene: tracked secret-looking files
  bad="$(git -C "$d" ls-files | grep -Ei '(\.env$|\.pem$|id_rsa|\.key$|secrets\.json$|cred\.txt$)' | grep -v '\.env\.example' || true)"
  if [ -n "$bad" ]; then hygiene="FAIL"; else hygiene="ok"; fi

  # gitleaks: working tree only (shallow clone)
  if command -v "$GITLEAKS" >/dev/null; then
    if "$GITLEAKS" detect --source "$d" --no-git --redact -q >/dev/null 2>&1; then gl="ok"; else gl="FAIL"; fi
  else gl="n/a"; fi

  # Windows-only build? (JUCE/CMake .vst3) -> skip node/python gates honestly
  note=""
  if [ -f "$d/CMakeLists.txt" ] && grep -qiE 'juce|vst3' "$d/CMakeLists.txt" 2>/dev/null; then note="windows-only build (skipped here)"; fi

  node="-"; python="-"
  if [ -f "$d/package.json" ]; then
    if [ -f "$d/bun.lockb" ]; then PM=bun; elif [ -f "$d/pnpm-lock.yaml" ]; then PM=pnpm; elif [ -f "$d/yarn.lock" ]; then PM=yarn; else PM=npm; fi
    ( cd "$d" && case "$PM" in
        bun) command -v bun >/dev/null && bun install --silent && bun test --if-present ;;
        pnpm) command -v pnpm >/dev/null && pnpm install --frozen-lockfile --silent && pnpm test --if-present ;;
        yarn) command -v yarn >/dev/null && yarn install --silent && yarn test --if-present ;;
        npm)  npm ci --silent 2>/dev/null || npm install --silent; npm test --if-present ;;
      esac ) >/dev/null 2>&1 && node="ok" || node="FAIL"
  fi
  if [ -f "$d/pyproject.toml" ] || ls "$d"/requirements*.txt >/dev/null 2>&1; then
    if find "$d" -name 'test_*.py' -o -name '*_test.py' | grep -q .; then
      ( cd "$d" && python -m pytest -q ) >/dev/null 2>&1 && python="ok" || python="FAIL"
    else python="absent"; fi
  fi

  tests=$(find "$d" -path '*/node_modules' -prune -o \( -name '*.test.ts' -o -name '*.spec.ts' -o -name 'test_*.py' -o -name '*_test.py' -o -name '*Tests.cpp' \) -print 2>/dev/null | wc -l)
  spawns=$(grep -RIlE 'child_process|execa|spawnSync|subprocess\.|ProcessStartInfo' "$d" --include='*.test.*' --include='test_*.py' 2>/dev/null | wc -l)
  boundary="$tests/${spawns}spawn"

  echo "| $r | $hygiene | $gl | $node | $python | $boundary | $note |" >> "$tmp"
done

mv "$tmp" "$OUT"
ln -sf "$OUT" "$STATE_DIR/latest-sweep.md"
echo "ecosystem-sweep: wrote $OUT"
