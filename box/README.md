# Box-side watch

The ecosystem clock that does **not** depend on GitHub Actions. Runs on the
always-on host (Oracle Cloud Always Free ARM / a Hetzner CX23) from cron. This
is the fallback the account needs while GitHub Actions is blocked
(0-step setup failures account-wide) — and it is the durable answer regardless,
because it costs no CI minutes and no vendor dependency.

## Files

| file | purpose | cron |
|---|---|---|
| `ecosystem-watch.sh` | nightly API sweep (alerts, staleness, last run, PRs) | `17 9 * * *` |
| `ecosystem-sweep.sh` | weekly full sweep (hygiene, gitleaks, node/python, boundary signal) | `0 10 * * 0` |
| `install-cron.sh` | installs the two cron entries (idempotent) | — |
| `notify.sh` | optional hook; called with the report path if present and executable | — |

Reports land in `~/fleet-ops/watch/` (`latest.md` / `latest-sweep.md` are symlinks).

## Setup on the box (Ubuntu / Oracle ARM)

```bash
# 1. deps
sudo apt-get update && sudo apt-get install -y jq git curl
# gh CLI (official apt repo)
(type -p wget >/dev/null || sudo apt-get install -y wget) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
  && sudo apt-get update && sudo apt-get install -y gh
# gitleaks (release binary)
GL=8.21.2; curl -sSL "https://github.com/gitleaks/gitleaks/releases/download/v${GL}/gitleaks_${GL}_linux_arm64.tar.gz" | sudo tar -xz -C /usr/local/bin gitleaks

# 2. auth — token is resolved from Keywire; never paste it into a command history
gh auth login   # device flow, OR: export GH_TOKEN=<from Keywire>

# 3. fetch fleet-ops and install cron
git clone https://github.com/ncsound919/fleet-ops ~/fleet-ops
~/fleet-ops/box/install-cron.sh --apply

# 4. prove it (does not wait for cron)
~/fleet-ops/box/ecosystem-watch.sh && cat ~/fleet-ops/watch/latest.md
```

## Honest limitations

- **Working-tree-only secret scan:** `ecosystem-sweep.sh` shallow-clones and runs
  `gitleaks --no-git`, so a leak that exists *only* in history is not caught here
  (the CI job in `fleet-ops` uses full history when Actions works again).
- **Windows-only targets are skipped, not passed.** JUCE/CMake `.vst3` repos
  (ChordStudio) cannot build on the Linux box; the sweep says so in the `note`
  column rather than returning a false green.
- **2-core box:** the sweep is serial and shallow on purpose; it does not attempt
  the heavy sanitizer/build lanes the existing CI does.
- **No exit-on-red gate yet:** the box watch is report-only until the verifier is
  trusted (same posture as the GitHub sweep).
