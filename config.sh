# pr-autopilot configuration (sourced by autopilot.sh)

OWNER="keanehatescoding"
EXCLUDE_REPOS="Server-Admin-Github-Runners CyberShield hp-245-g10-mic-mute-led pr-autopilot"            # space-separated repo names the bot must never touch

# ---- Claude budget (the plan is also used interactively) -------------------------------------
# Before every Claude run the bot reads the plan's real utilization.
# Two numbers matter: the 5-hour window and the 7-day window.
#
# WEEK_TARGET: total weekly utilization (everyone combined) the bot paces toward.
#   The bot only runs while   used_so_far < WEEK_TARGET * fraction_of_week_elapsed
#   so it can never front-load, and whatever is used interactively comes out of
#   the bot's share. At 95, with ~20% interactive use, the bot gets ~75% of the week.
WEEK_TARGET=95
DAILY_MAX=12                # never let weekly utilization grow more than this many points in one day
FIVE_HOUR_MAX=60            # don't start a run if the 5-hour window is already this full
MAX_RUNS_PER_DAY=10         # backstop in case the usage reading ever misbehaves

# Hours (local, 24h) in which Claude runs may START. Free GitHub actions
# (merging, asking CodeRabbit to re-review) happen at any hour.
# Set both to 0 to allow any hour.
WINDOW_START=1
WINDOW_END=7

MODEL="sonnet"
MAX_TURNS=30                # max agent steps per run
RUN_TIMEOUT="40m"

# ---- Free agents (opencode / kilo free models: no Claude plan usage) ------
# Tried first for every fix and discovery, in this order, at any hour. Claude is the
# fallback: it takes over a task after FREE_TRIES failed free attempts, and does
# fix rounds after FREE_MAX_ROUNDS. Set FREE_AGENTS=() to use Claude only.
# List free models with: opencode models | grep free   /   kilo models | grep free
# Each model has its own cooldown, so beam-free takes over when deepseek's free quota runs out.
FREE_AGENTS=("opencode:opencode/deepseek-v4.1-flash-free" "opencode:opencode/beam-free" "kilo:kilo/kilo-auto/free")
# FREE_AUTO=1: try every free model the CLIs list on a small trial task (idle ticks, free) and
# use the best FREE_MAX_MODELS first; FREE_AGENTS above is the fallback and gets tried first.
# See: ./autopilot.sh models   /   ./autopilot.sh trial [agent:model|all|new]
FREE_AUTO=1
FREE_MAX_MODELS=5
FREE_SKIP=()                # agent:model (or model) never to use, e.g. ("kilo:kilo/liquid/lfm-3-1.7b:free")
TRIAL_TIMEOUT=10m
FREE_TRIES=2                # failed free attempts on one task before Claude takes over
FREE_MAX_ROUNDS=3           # free agents may do fix rounds 1..3 of a PR; later rounds go to Claude
FREE_EXTRA_ROUNDS=1         # when Claude can't take a later round (hours, budget), a free model new to the PR
                            # may do up to this many more; the last of MAX_FIX_ROUNDS always waits for Claude
FREE_TIMEOUT="30m"
FIX_MORE_WITHIN=15          # a tick done within this many minutes takes another queued PR (free models only; 0 = one fix per tick)
FREE_COOLDOWN_MIN=60        # an agent that errors out (rate limit, outage, bad output) is skipped this long
DEPS_TIMEOUT="10m"          # dependency install (npm ci / uv sync ...) before an agent runs, inside the sandbox
MAX_DISCOVERIES_PER_DAY=6   # new-work scans per day (any agent), so free runs can't flood repos with issues

# Extra shell commands for free agents only. Safe because they run in a bubblewrap
# sandbox that only shows them the repo (see sandbox_for in autopilot.sh).
FREE_EXTRA_BASH=(cat grep rg sed sort uniq cut tr diff "git --no-pager diff" "git --no-pager log" "git --no-pager show")

# Agents' commits may not touch these (regex on paths). They could loosen the next
# agent's sandbox, plant instructions for it, or run code with repo secrets in CI.
# A commit that does is discarded (free agent) or handed to a human (Claude).
# .githooks/: hooks run on YOUR machine when you commit/push in your own clone after a merge.
PROTECTED_PATHS='(^|/)(CLAUDE\.md|AGENTS\.md|\.mcp\.json|opencode\.jsonc?|kilo\.jsonc?)$|^\.(github/workflows|githooks|claude|opencode|kilo|kilocode)/'

# ---- Notifications --------------------------------------------------------
# Desktop pop-ups (notify-send) on errors, crashed ticks and PRs handed to you
# (needs-human / stuck). The same alert is not repeated within NOTIFY_REPEAT_HOURS.
NOTIFY_REPEAT_HOURS=6
# Optional phone push: install the ntfy app and run  ./autopilot.sh set-ntfy-topic
# The topic is kept in state/ntfy-topic, not here: anyone who knows it can read the alerts, and this
# file is committed.

# ---- PR flow ---------------------------------------------------------------
AUTO_MERGE=1                # 1 = merge clean PRs; 0 = label them "autopilot-ready" instead
# A PR merges only when ALL hold for its latest commit:
#   - CI passed
#   - CodeRabbit: "No actionable comments were generated in the recent review" for this commit
#   - Claude:     "No issues found. Checked for bugs and CLAUDE.md compliance." posted after this commit
#   - no unresolved review threads, no merge conflict
# REQUIRE_CLAUDE_REVIEW: auto   = require Claude's verdict only where the Claude review check runs
#                                 (today: antivirus_x86-64, antivirus_arm64)
#                        always = never merge without it (repos lacking the workflow won't auto-merge)
#                        never  = ignore it
REQUIRE_CLAUDE_REVIEW="auto"   # Claude reviews a PR once (its plugin skips PRs it commented on); that review carries over to later bot fixes
CLAUDE_REVIEW_CHECK='^claude-review$'   # name of the CI check that runs the Claude review
MERGE_METHOD="squash"       # squash | merge | rebase
MAX_OPEN_PRS=4              # bot PRs open at once across all repos
DIGEST_HOUR=9               # daily digest notification after this hour (empty = off)
MAX_FIX_ROUNDS=5            # after this many fix attempts a PR is labelled autopilot-stuck
CR_COOLDOWN_MIN=62          # CodeRabbit free plan: wait this long between review requests
REDISCOVER_DAYS=3           # don't hunt for new work in the same repo more often than this
SIGN_COMMITS=1              # sign bot commits with its own SSH key (./autopilot.sh signing-key) when the key exists

# ---- Disk (daily cleanup; ./autopilot.sh cleanup runs it now) ---------------
WT_KEEP_DAYS=7              # remove a repo's worktree (deps, builds) after this many idle days with no open bot PR
RUN_LOG_KEEP_DAYS=30        # delete per-run agent transcripts (logs/*.jsonl, *.err, deps-*.log) older than this; day logs stay
CACHE_MAX_MB=200            # empty an agent download cache (uv, npm) once it holds more than this on its own

# Review comments from these logins (regex) are treated as feedback to address.
TRUSTED_REVIEWERS='^(coderabbitai|claude|github-actions)'

# Tools loaded into Claude's context at all. Fewer tools = smaller prompt on every turn
# (this set is ~8k tokens vs ~15k for the default set) and no subagent spawning.
RUN_TOOLS="Bash,Read,Edit,Write,Glob,Grep,TodoWrite"

# Commands Claude may run unattended. Anything else is denied automatically.
# It has no gh, no git push and no network fetch tools: the script does all GitHub actions.
ALLOWED_TOOLS=(
  Read Edit Write Glob Grep TodoWrite
  "Bash(git status:*)" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)"
  "Bash(git add:*)" "Bash(git commit:*)" "Bash(git rm:*)" "Bash(git mv:*)"
  "Bash(git restore:*)" "Bash(git grep:*)" "Bash(git blame:*)"
  "Bash(ls:*)" "Bash(wc:*)" "Bash(head:*)" "Bash(tail:*)" "Bash(find:*)"
  "Bash(npm test:*)" "Bash(npm run:*)" "Bash(npm ci:*)" "Bash(npm install:*)"
  "Bash(npx tsc:*)" "Bash(npx eslint:*)" "Bash(npx vitest:*)" "Bash(npx jest:*)" "Bash(npx prettier:*)"
  "Bash(pytest:*)" "Bash(python -m pytest:*)" "Bash(python3 -m pytest:*)"
  "Bash(python3 -m py_compile:*)" "Bash(ruff:*)" "Bash(mypy:*)"
  "Bash(make:*)" "Bash(cmake:*)" "Bash(gcc:*)" "Bash(clang:*)" "Bash(cppcheck:*)"
  "Bash(./gradlew:*)" "Bash(cargo:*)" "Bash(go test:*)" "Bash(go build:*)" "Bash(go vet:*)"
  "Bash(shellcheck:*)" "Bash(bash -n:*)"
)

# Where your own clones live. The bot makes git worktrees from them (in ~/pr-autopilot/worktrees)
# and never touches your checkout, branches or uncommitted changes.
LOCAL_ROOTS=("$HOME/Projects" "$HOME/projects" "$HOME")
