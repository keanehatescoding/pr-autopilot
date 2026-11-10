# pr-autopilot

Runs every 20 min (systemd user timer). Each tick:

1. **Free (no Claude):** loads every open PR labelled `autopilot` across your repos and for each one:
   - **Merge** (squash) only when, for the latest commit: CI passed, CodeRabbit's summary says
     "No actionable comments were generated in the recent review" *for that commit*, Claude's review posted
     *after that commit* says "No issues found. Checked for bugs and CLAUDE.md compliance." (required where the
     `claude-review` check runs; see `REQUIRE_CLAUDE_REVIEW`), and there are no open threads or conflicts.
   - **Behind its base?** Before merging, the bot has GitHub merge the base into the branch ("Update branch",
     free). CI must pass again on that commit; the review verdicts carry over (it only adds already-merged code).
   - **No CI checks at all** (after 30 min) never counts as passed: a PR that is otherwise clean is labelled
     `autopilot-ready` and you get a notification to merge it yourself.
   - Claude review findings are fed to the fix run just like CodeRabbit comments.
   - CodeRabbit hasn't reviewed the latest commit → post `@coderabbitai review`, at most once per 62 min
     across *all* repos (free plan limit; your repos have <10 stars so CodeRabbit never auto-reviews).
   - CI failed / CodeRabbit left comments / merge conflict → queue a **fix** run.
2. **One agent run per tick:**
   - a queued fix (address threads, fix CI, resolve conflicts → commit; script pushes, replies, resolves threads), or
   - if fewer than `MAX_OPEN_PRS` (4) bot PRs are active: **discovery** in the next repo → opens a PR (+ issue), an
     issue, or a discussion (at most `MAX_DISCOVERIES_PER_DAY`, 6). PRs waiting on you (labelled needs-human, stuck,
     or ready but not mergeable by the bot: no CI, approval required) are parked and don't hold a slot; at 8 open
     bot PRs in all, no new work starts. `./autopilot.sh status` shows the slots and why discovery waits.

## Which agent runs
1. **Free agents first, any hour:** the free models of opencode, kilo, agy and vibe, best first by their trial scores
   and live results (`./autopilot.sh models`). These cost no Claude usage. A model that errors or returns garbage is
   skipped for 60 min (longer when its provider names a quota reset), so the next one is tried.
2. **Claude (Sonnet) as fallback, only when the budget allows:** it takes over a task after 2 failed free attempts
   (no result, no changes, asked for a human, unsafe commit), and does fix rounds 4–5 of a PR.
The merge rule is the same whoever wrote the code.

Every agent, Claude included, runs inside a **bubblewrap sandbox** (`sandbox_for`): they see only `/usr`, `/etc`,
the worktree, the repo's git data (your clone's config, hooks and refs read-only) and read-only toolchains
(`~/.local/bin`, uv's pythons/tools, pnpm, rustup). Your home folder, ssh keys, gh login, ~/.gitconfig, your
`~/.claude` login and the bot's own files are invisible.
Claude logs in with the **bot's own token** (`state/claude-token`, made with `claude setup-token`; same plan, same
budget gates). It is handed over on a file descriptor and scrubbed from the commands Claude runs. Without a token
the Claude fallback is off (you get one notification) and free agents keep working. On top of that,
a bot-only config (`state/agent-config`, from `ALLOWED_TOOLS` + `FREE_EXTRA_BASH`) denies by default: no gh,
git push or web, and none of your own opencode/kilo configs, plugins or MCP servers. If an agent edits files but
can't commit, the bot commits them for it. Their session history lives in `state/agent-data`, not in your app. Repos that contain their own
opencode/kilo config go straight to Claude. Any agent's commit touching `.github/workflows`, `CLAUDE.md`,
`AGENTS.md`, `.claude/`, `.mcp.json` or opencode/kilo config is never pushed (`PROTECTED_PATHS`).
Note: free models may let their provider log or train on the code they see (you chose: all repos).

**Dependencies:** before an agent runs, the bot installs the repo's dependencies inside the sandbox
(`npm ci`, `pnpm`/`yarn`/`bun install`, `uv sync`, or `uv pip install -r requirements*.txt`), so agents can run
tests. It is skipped while the lockfiles are unchanged (`state/deps`). Install scripts run sandboxed with no
secrets visible. `node_modules/`, `.venv/` and similar are never committed (bot-only git excludes). They stay in
the worktree between runs (~0.5 GB per JS/Python repo).

**Secret scan:** nothing the bot posts (PR/issue/discussion text, review replies, comments) and no commit it
pushes may contain a credential: common token formats (GitHub, Anthropic, OpenAI, AWS, Slack, Google, private
keys) or the exact value of your own gh/opencode/kilo/Claude logins. A hit is blocked and alerted; a blocked
push is saved as a patch in `state/blocked/` (mode 600) and the PR gets `autopilot-needs-human`. Notifications
that would carry such text are withheld too.

## Budget (the plan is also used interactively)
Before each Claude run it reads the plan's real utilization (a ~3k-token Haiku call, skipped when the last
reading, e.g. the one every Sonnet run returns, is under 10 min old) and only runs if:
- weekly usage < `WEEK_TARGET` (95%) × fraction of the week elapsed (pacing, counts everyone's usage),
- weekly usage grew < `DAILY_MAX` (12 points) today,
- 5-hour window < `FIVE_HOUR_MAX` (60%),
- it's between `WINDOW_START`–`WINDOW_END` (1am–7am).

A fix that no agent can take for `CLAUDE_WAIT_HOURS` (24) on the same commit, because its free tries are used and Claude is
blocked by hours or budget, is labelled `autopilot-needs-human` and you get an alert.

## Notifications
Desktop pop-ups (notify-send) when:
- a tick crashes or times out (critical; systemd `OnFailure=pr-autopilot-failed.service`),
- something fails: push, worktree setup, a refused merge, creating a PR/issue/discussion, GitHub unreachable,
  the plan limit is hit (critical),
- both free agents are failing at once,
- a PR is handed to you: `autopilot-needs-human` or `autopilot-stuck` (with the reason and link).
The same alert is not repeated within `NOTIFY_REPEAT_HOURS` (6). For phone pushes, run
`./autopilot.sh set-ntfy-topic` (paste a topic, or press Enter for a new random one) and subscribe to it in the
ntfy app. The topic is stored in `state/ntfy-topic`, outside the repo, because anyone who knows it can read the alerts.

## Commands
    ./autopilot.sh status              # bot PRs, today's runs, last usage reading
    ./autopilot.sh set-ntfy-topic      # set or change the phone-alert topic (kept out of the repo); sends a test alert
    ./autopilot.sh doctor              # health check: tools, config, logins, timer, last tick, secrets, disk (exit 1 on a FAIL)
    ./publish.sh                       # publish the committed code to the public GitHub repo as one snapshot commit (history and tags stay local)
    ./autopilot.sh usage               # read plan usage now
    DRY_RUN=1 ./autopilot.sh tick      # show decisions, change nothing
    ./autopilot.sh selftest            # run each free agent in a throwaway repo; checks the sandbox holds (incl. a canary file outside it)
    ./autopilot.sh notify-test         # send a test notification
    ./autopilot.sh set-claude-token    # save the bot's Claude token (from `claude setup-token`) and test it
    ./autopilot.sh version             # the running install: fix31, fix31+2 (commits since), -dirty (uncommitted edits)
    tests/run.sh [new-autopilot.sh]    # free replay tests (saved real agent logs, sandbox config, secret scan); run before installing a change
    ./install.sh new.sh message.txt    # test, back up (state/autopilot.sh.bakN), swap in atomically, commit, tag fixN
    ./install.sh --rollback fixN       # put an earlier install back; --check new.sh runs the checks only
    touch PAUSE / rm PAUSE             # stop / resume all agent runs (free and Claude) instantly
    systemctl --user enable --now pr-autopilot.timer    # turn on
    systemctl --user disable --now pr-autopilot.timer   # turn off
    journalctl --user -u pr-autopilot  /  logs/YYYY-MM-DD.log

Changing the bot: build the new autopilot.sh beside it, `git add` any test or config changes that go with it,
then run install.sh. It refuses while a tick is running, when the tests fail, or when the live file has
uncommitted edits. Every tick logs the version it ran as (`=== tick [fix31]`), so a bad tick maps to its install.

Labels: `autopilot` (bot PR), `autopilot-ready`, `autopilot-stuck` (5 fix rounds used), `autopilot-needs-human`.
Put `autopilot-skip` on an issue to keep the bot off it. Add repo names to `EXCLUDE_REPOS` to keep it out entirely.
Code work happens in git worktrees made from your own clones (found under `LOCAL_ROOTS`), at
`~/pr-autopilot/worktrees/<repo>`, with a detached HEAD. Fetch and push go over HTTPS with your gh login. Your
checkout, branches and uncommitted changes are never touched; the only trace in your clone is the entry in
`git worktree list` and refreshed `origin/*` refs. Repos you haven't cloned get a bot-only clone in `repos/`.
Excluded for now: Server-Admin-Github-Runners, CyberShield, hp-245-g10-mic-mute-led.
The computer must be on and you logged in (locked screen is fine) for ticks to run.
