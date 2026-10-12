# fleet-ops

Central control plane for the BUSINESS ecosystem. **Ecosystem Watch** is the
clock: it runs on GitHub's hardware so the work does not depend on the operator's
laptop being awake, and it reports where the repos actually stand.

## What it does

`.github/workflows/ecosystem-watch.yml`

| when | job | what | cost |
|---|---|---|---|
| nightly `09:17 UTC` | `nightly` | API-only metadata sweep: open Dependabot + secret-scanning alerts, days since last push, most recent CI run, open PRs | seconds/repo |
| weekly `Sun 10:00 UTC` | `sweep` | matrix checkout of every owned repo: hygiene (tracked secrets), gitleaks, node/python build+test, **boundary-test signal** | minutes/repo |
| `workflow_dispatch` | both (per `full`) | manual trigger; `full=true` runs the checkout sweep | as above |
| after either | `report` | aggregates into the run summary, uploads artifacts, and upserts one tracking issue titled **Ecosystem Watch** | ~0 |

Run the sweep manually once at any time:

```bash
gh workflow run ecosystem-watch.yml -f full=true
gh workflow run ecosystem-watch.yml -f full=false -f "repos=recourse,openhub,keywire"
```

## Why it exists

- The laptop cannot stay up (measured: 15.7 GB RAM, 3.4 GB free, no CUDA). The
  always-on spine belongs off-box; the scheduled audit can live on free Actions
  runners today.
- The recurring defect in the lesson corpus is the **silent pass**: a green suite
  that never touches the real artifact. The `sweep` reports the boundary-test
  signal (how many test files, how many spawn a real process/engine) so "green"
  is read next to "did it exercise anything real".

## Required secret

`FLEET_PAT` - a token with `repo` (read for private repos) + `issues:write`. It is
used to enumerate the account's repos, check them out, and post the report.
Set it once:

```bash
gh secret set FLEET_PAT -R ncsound919/fleet-ops    # paste the token value when prompted
```

> **Rotate now.** Two repos in the local tree (`SKILLS/Skilltech/Middle-Man-MCP`
> and `SKILLS/Skilltech/OG-Glass`) had the GitHub PAT embedded in their
> `origin` URL (`.git/config`). That token is compromised; rotate it and re-run
> `git remote set-url origin https://github.com/ncsound919/<repo>.git` in both
> before setting `FLEET_PAT`.

## Minutes budget (be honest about it)

GitHub Free gives **2,000 Actions minutes/month** for **private** repos (unlimited
for public; self-hosted runners are always free). The nightly lane is
API-only (~1 job), so it is cheap. The weekly sweep is the cost:

```
minutes/week  ~=  repos x per-repo-minutes
30 repos x ~3 min  ~= 90 min/week  ~= 360 min/month   (fits 2,000)
```

If the sweep grows, either (a) run it monthly, (b) restrict `repos=`, or (c) move
it to a **self-hosted runner** on the always-on box (free minutes regardless of
privacy). Until the verifier is trusted, the watch is **report-only** - it never
enqueues repairs.
