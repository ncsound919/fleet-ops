# Phone ops — running this ecosystem with no laptop

**State 2026-10-16.** Written because the operator loses the laptop tomorrow. The
research was already done on 2026-10-12 (`plans/2026-10-12-compute-schedule-and-delegation.md`);
this file is the *operational* short form plus the two phone-lane pieces that
were missing.

## The lane, in one paragraph

**Track:** the nightly `ecosystem-watch.sh` writes a report and calls
`~/fleet-ops/notify.sh`, which pushes it to your phone (Telegram). A second copy
lands in the **"Ecosystem Watch" issue** on GitHub — that is the phone dashboard,
free, already wired. **Steer:** `box/steer.sh` long-polls Telegram and runs a
fixed verb table on the always-on box — `/status`, `/watch`, `/sweep`, `/repos`,
`/help`. There is **no free-form shell**; the allowlisted chat id is the only
caller that is obeyed.

## What already exists — do not rebuild

| Piece | State |
|---|---|
| `fleet-ops/box/` watch + sweep + cron installer | written, targets Ubuntu/ARM |
| `fleet-ops` GitHub workflows | written; **GitHub Actions is blocked account-wide** (0-step setup failures) so the box cron is the lane of record |
| AWS EC2 LiteLLM gateway `3.147.69.85:4100` | **live, reboot-proven** — the one always-on service today |
| S3 backups + restore drill | verified 2026-10-12 |
| Infisical vault | **cloud SaaS — already off-box** (Keywire retired 2026-10-15) |
| Host decision **H2 = Oracle Cloud Always Free ARM** | decided 2026-10-12; **still unbuilt** — this is the gap |

## The 24-hour sequence

### Step 0 — before the other session pushes anything

Measured this session: `reporank` and `Grader-main` both **gitignore `.env`**
(`.gitignore:30:.env`, `.gitignore:19:.env`); only `.env.example` is tracked, and
`Grader-main/.env.test`'s values are short placeholders (a fake `GITHUB_TOKEN` is
17 chars; a real PAT is ~93). So a normal `git add`/`push` is safe. The residual
risks, in order:

1. **Rotate the fleet GitHub PAT.** `fleet-ops/README.md` records that two repos
   (`Middle-Man-MCP`, `OG-Glass`) once carried the PAT in their `origin` URL. If
   that PAT is still live, rotate it before it becomes the account-wide token.
2. **Never `git add -f` a `.env`, and never `git init` inside `~/.config/opencode`
   or `~/.dsh`** — those dirs are *not* repos and hold `.secrets/` and
   `.credentials.yaml`. A scan is the only proof: run
   `git ls-files | grep -Ei '(\.env$|\.pem$|id_rsa|\.key$)'` per repo (the sweep
   does exactly this) or `gitleaks detect` where available.

### Step 1 — operator, ~10 minutes, the only irreducible account step

Create the Oracle Cloud Free Tier account (real credit/debit card for identity;
no prepaid/virtual; one account per person). Then create the ARM instance
(Ampere A1). **Capacity is a lottery** — if "out of host capacity", retry
another availability domain; this is normal and not a failure of the plan.
Ubuntu 22.04/24.04 ARM image.

### Step 2 — scripted provisioning (agent does this)

```bash
# deps
sudo apt-get update && sudo apt-get install -y jq git curl
# gh CLI — see box/README.md for the apt-repo block
# gitleaks — see box/README.md
# clone + clock
git clone https://github.com/ncsound919/fleet-ops ~/fleet-ops
~/fleet-ops/box/install-cron.sh --apply
~/fleet-ops/box/ecosystem-watch.sh && cat ~/fleet-ops/watch/latest.md
# make the two new files executable, or the hook is silently skipped:
chmod +x ~/fleet-ops/notify.sh ~/fleet-ops/box/steer.sh
```

`~/.fleet-ops.env` (chmod 600, never committed):

```
TELEGRAM_BOT_TOKEN=...   # from @BotFather
TELEGRAM_CHAT_ID=...     # your chat with the bot
STEER_CHAT_ID=...        # same number; the allowlist
GH_TOKEN=...             # from Infisical
```

### Step 3 — operator, ~2 minutes: the bot

Open **@BotFather** on the phone → `/newbot` → name it → copy the token into
`~/.fleet-ops.env`. Send the bot any message, then get your chat id from
`https://api.telegram.org/bot<TOKEN>/getUpdates` (the `chat.id` field). Store
`TELEGRAM_BOT_TOKEN` in Infisical too (project o365) so it survives the box.

### Step 4 — prove the round trip

`nohup ~/fleet-ops/box/steer.sh >/dev/null 2>&1 &` then send `/status` from the
phone. Then wait for cron at 09:17 UTC (or run `ecosystem-watch.sh` by hand) and
confirm the report arrives as a push.

### Step 5 — the agent lane

Only after the box answers `/status`. Then install the agent runtime on the box
(Node + the harness) and add a `/run` verb that dispatches a job — do **not**
give the phone a shell.

## Honest limits

- **The ~40 local services do not move.** The ecosystem's own plan puts only a
  *tiny resident spine* off-box (relay, degoog, an LLM gateway, Dev-Brain, plus
  Postgres/Redis and optionally a self-hosted Actions runner). Everything else
  becomes on-demand work. "The entire ecosystem operating remote" is not a thing
  that exists; a small always-on core plus on-demand jobs is what the plan
  actually says.
- **ARM64**: native deps (better-sqlite3, Playwright browsers, any prebuilt
  x64 binary) may need a rebuild. Test on the box, do not assume.
- **Free-tier reclamation**: Oracle reclaims free instances when 7-day p95 CPU
  **and** network **and** memory are all <20%. The cron + steer poller keep it
  non-idle; that is also why the poller matters beyond convenience.
- **Unverified here**: the Telegram send paths of `notify.sh` / `steer.sh` were
  syntax-checked and their refusal guards proved to exit non-zero, but this
  laptop's WSL image has no `jq`/`curl`, so no message was sent. First `/status`
  on the box is the proof.

## The app, honestly

Phase 1 (tonight → tomorrow) **Telegram is the app**: zero install, push
notifications, works on any phone. Phase 2's native app is a client over exactly
two things — the report files in `~/fleet-ops/watch/` and the verb table above
(plus a `status --json` when the box exists). Building it before the box exists
would steer nothing.
