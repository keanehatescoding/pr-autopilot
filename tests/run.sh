#!/usr/bin/env bash
# Replay tests for autopilot.sh: saved agent logs (tests/fixtures, copied from real runs in logs/)
# go through the event parsers, plus the agent config, agy write grant, secret scan and tick timing.
# Free: no agents, no network, no Claude. Runs against a scratch state, never the live bot's.
#   tests/run.sh                  test ./autopilot.sh
#   tests/run.sh path/to/new.sh   test a candidate before installing it
set -uo pipefail
T=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); F=$T/fixtures; W=$T/.work/run
SRC=$(realpath "${1:-$T/../autopilot.sh}")
PASS=0; FAILS=()
ok()  { local n=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); else FAILS+=("$n"); fi; }
no()  { local n=$1; shift; if "$@" >/dev/null 2>&1; then FAILS+=("$n"); else PASS=$((PASS+1)); fi; }
eq()  { if [[ $2 == "$3" ]]; then PASS=$((PASS+1)); else FAILS+=("$1: expected [$2], got [${3:0:200}]"); fi; }
has() { if [[ $3 == *"$2"* ]]; then PASS=$((PASS+1)); else FAILS+=("$1: [$2] not in [${3:0:200}]"); fi; }

bash -n "$SRC" || { echo "FAIL: syntax error in $SRC"; exit 1; }
[[ $(tail -1 "$SRC") == 'main "$@"; exit $?' ]] || { echo "FAIL: $SRC does not end in the main call"; exit 1; }
mkdir -p "$W"; [[ -d $W/state ]] && find "$W/state" -mindepth 1 -delete
[[ -d $W/logs ]] && find "$W/logs" -mindepth 1 -delete   # the digest test leaves a day log that broke a second run that day
sed '$d' "$SRC" > "$W/lib.sh"; cp "$T/../config.sh" "$W/config.sh"
# shellcheck source=/dev/null
source "$W/lib.sh"
set +e
STATE=$W/state; LOG=$W/log; LOGS=$W/logs; AGENT_CFG=$STATE/agent-config; AGENT_DATA=$STATE/agent-data
CLAUDE_TOKEN_FILE=$STATE/claude-token; MODEL_TRIALS=$STATE/model-trials.json
mkdir -p "$STATE" "$LOGS" "$AGENT_CFG"
HOME=$W/home; mkdir -p "$HOME"                       # no real logins in known_secrets
gh() { [[ "$*" == "auth token" ]] && echo "fakeGhToken0123456789abcdefXYZ"; }
fix='{"required":["summary","declined","needs_human"]}'; trial='{"required":["fixed","summary"]}'

# ---- parsers on real runs -------------------------------------------------------------------
# opencode beam, 2026-11-09 16:41: 121 malformed tool calls for 20 min, then a made-up "fixed" claim
o=$F/opencode-2026-11-09-164117-fix-anticheat_x86-64-120.jsonl
ok  "beam loop: free_stuck"            free_stuck "$o"
eq  "beam loop: tool calls"            121 "$(free_tools "$o" | wc -l)"
eq  "beam loop: none completed"        0 "$(free_tools "$o" completed | jq -s 'map(select(.o | test("No tool named") | not)) | length')"
# the same PR's next run: a real fix
o=$F/opencode-2026-11-09-170115-fix-anticheat_x86-64-120.jsonl
no  "beam fix: not stuck"              free_stuck "$o"
has "beam fix: result"                 'Applied both review fixes' "$(free_result "$o" "$fix" | jq -r .summary)"
has "beam fix: session"                ses_ "$(free_session "$o")"
eq  "beam fix: not limited"            "" "$(free_limited "$o")"
# rate limits: kilo lfm "temporarily rate-limited upstream" (no retry time), opencode 429 with retryAfterMs
eq  "kilo upstream limit"              0 "$(free_limited "$F/kilo-2026-11-09-150047-trial.jsonl")"
eq  "opencode 429 retry time"          15262 "$(free_limited "$F/opencode-2026-11-07-225409-selftest.jsonl")"
# agy weekly quota, 2026-11-09 20:46: "Resets in 165h54m52s" (it was cooled for 1h and would retry hourly)
eq  "agy quota reset time"             597292 "$(free_limited "$F/agy-2026-11-09-204032-discover-campus-vlan-radius-lab.jsonl")"
# kilo trials: a JSON result, and a run that ended without one (gets the follow-up turn)
eq  "kilo easy: fixed"                 true "$(free_result "$F/kilo-2026-11-09-180232-trial-easy.jsonl" "$trial" | jq -r .fixed)"
eq  "kilo hard: no JSON"               "" "$(free_result "$F/kilo-2026-11-09-180321-trial-hard.jsonl" "$trial")"
# agy 18:41: edits under /home denied (write_file leaves no step; only the result lists it)
o=$F/agy-2026-11-09-184117-trial-easy.jsonl
eq  "agy write denial: kind"           write_file "$(agy_denied "$o")"
eq  "agy write denial: no denied step" 0 "$(free_tools "$o" denied | wc -l)"
eq  "agy write denial: result"         false "$(free_result "$o" "$trial" | jq -r .fixed)"
# agy 19:22: a denied command (shape B, ERROR step), resumed, then fixed
o=$F/agy-2026-11-09-192240-trial-hard.jsonl
has "agy cmd denial: named"            'python3 -c "print(any(' "$(free_tools "$o" denied | jq -r .c)"
eq  "agy cmd denial: result"           true "$(free_result "$o" "$trial" | jq -r .fixed)"
eq  "agy auto-denied text is no limit" "" "$(free_limited "$o")"
# agy 18:21: one denied command, then a denied write the old parser named as a command (diag.sh)
o=$F/agy-2026-11-09-182132-fix-anticheat-arm64-138.jsonl
eq  "agy fix: only the real command"   'command -v setsid' "$(free_tools "$o" denied | jq -r .c)"
eq  "agy fix: last call denied nothing" "" "$(agy_denied "$o")"
ok  "agy fix: result has declined"     jq -e '.declined | length > 0' <<<"$(free_result "$o" "$fix")"
has "agy fix: session"                 - "$(free_session "$o")"
for o in "$F"/*.jsonl; do eq "no leak in $(basename "$o")" "" "$(leak_check "$o")"; done
# a run that reads the bot's own key file is a leak
printf '%s\n' '{"type":"tool_use","part":{"state":{"status":"completed","input":{"command":"cat ~/.vibe/.env"},"output":"x"}}}' > "$W/leak.jsonl"
has "reading .vibe/.env is a leak"     .vibe/.env "$(leak_check "$W/leak.jsonl")"

# ---- agent config ---------------------------------------------------------------------------
agent_config >/dev/null 2>&1
v=$STATE/agent-home/.vibe/config.toml; a=$AGENT_CFG/agy-settings.json
ok  "vibe config parses"               python3 -I -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$v"
eq  "vibe: no Mistral co-author"       False "$(python3 -I -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb")).get("include_commit_signature"))' "$v")"
eq  "vibe: outside workdir denied"     deny "$(python3 -I -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["outside_workdir"])' "$v")"
eq  "vibe: git push denied"            True "$(python3 -I -c 'import sys,tomllib; print("git push" in tomllib.load(open(sys.argv[1],"rb"))["tools"]["bash"]["denylist"])' "$v")"
no  "vibe: git push not allowed"       python3 -I -c 'import sys,tomllib; sys.exit(0 if any(x.startswith("git push") for x in tomllib.load(open(sys.argv[1],"rb"))["tools"]["bash"]["allowlist"]) else 1)' "$v"
ok  "agy: git push denied"             jq -e '.permissions.deny | index("command(git push)")' "$a"
ok  "agy: no outside access"           jq -e '.allowNonWorkspaceAccess == false' "$a"
eq  "agy: no write grant by default"   0 "$(jq '[.permissions.allow[] | select(startswith("write_file"))] | length' "$a")"
k=$AGENT_CFG/kilo/kilo.json
# 21:03 kilo run ended on "read (radius/secrets.env); auto-rejecting": .env must be deny, never ask
eq  "kilo: .env read denied"           deny "$(jq -r '.permission.read["*.env"]' "$k")"
eq  "kilo: .env.* read denied"         deny "$(jq -r '.permission.read["*.env.*"]' "$k")"
eq  "kilo: catch-all read rule first"  '*' "$(jq -r '.permission.read | keys_unsorted[0]' "$k")"
eq  "kilo: doom_loop denied"           deny "$(jq -r '.permission.doom_loop' "$k")"
eq  "opencode: same permissions"       "$(jq -c .permission "$k")" "$(jq -c .permission "$AGENT_CFG/opencode/opencode.json")"

# ---- agy write grant: only the current run's directory ---------------------------------------
mkdir -p "$W/wt-a" "$W/wt-b"
agy_grant "$W/wt-a"; agy_grant "$W/wt-b"
eq  "agy grant: one, current dir"      "[\"write_file($W/wt-b)\"]" "$(jq -c '[.permissions.allow[] | select(startswith("write_file"))]' "$a")"
cp "$a" "$W/good.json"; echo 'not json' > "$a"
no  "agy grant: fails on bad settings" agy_grant "$W/wt-a"
eq  "agy grant: no temp file left"     "" "$(find "$AGENT_CFG" -name '*.new')"
cp "$W/good.json" "$a"
no  "agy grant: fails on missing dir"  agy_grant "$W/does-not-exist"

# ---- secret scan ----------------------------------------------------------------------------
mkdir -p "$STATE/agent-home/.vibe"; printf 'MISTRAL_API_KEY="FakeMistralKey0123456789abcdefABCD"\n' > "$STATE/agent-home/.vibe/.env"
eq  "secret: GitHub token pattern"     "a credential-looking string" "$(secret_in <<<"token ghp_$(printf 'a%.0s' {1..36})")"
eq  "secret: private key"              "a credential-looking string" "$(secret_in <<<'-----BEGIN OPENSSH PRIVATE KEY-----')"
eq  "secret: own gh token"             "one of your own tokens" "$(secret_in <<<'x fakeGhToken0123456789abcdefXYZ y')"
eq  "secret: bot's Mistral key"        "one of your own tokens" "$(secret_in <<<'key=FakeMistralKey0123456789abcdefABCD')"
no  "secret: ordinary diff"            secret_in <<<'+    return a + b  # fixed the sign'

# ---- timing and names -----------------------------------------------------------------------
eq  "git never falls back to the bot's own repo" "$W" "${GIT_CEILING_DIRECTORIES:-}"
eq  "dur_secs 30m"                     1800 "$(dur_secs 30m)"
eq  "dur_secs 2h"                      7200 "$(dur_secs 2h)"
eq  "cool_file name"                   "$STATE/agentcool/kilo_kilo_kilo-auto_free" "$(cool_file kilo:kilo/kilo-auto/free)"
eq  "multi-fix window, defaults"       900 "$(FIX_MORE_WITHIN=15 FREE_TIMEOUT=30m FREE_NUDGE_TIMEOUT=5m fix_more_window)"
eq  "multi-fix window, 45m runs"       300 "$(FIX_MORE_WITHIN=15 FREE_TIMEOUT=45m FREE_NUDGE_TIMEOUT=5m fix_more_window)"
ok  "multi-fix window, 55m runs: none" test "$(FIX_MORE_WITHIN=15 FREE_TIMEOUT=55m FREE_NUDGE_TIMEOUT=5m fix_more_window)" -lt 0
eq  "multi-fix window, off"            0 "$(FIX_MORE_WITHIN=0 FREE_TIMEOUT=30m FREE_NUDGE_TIMEOUT=5m fix_more_window)"

# ---- script-error alerts: the same bug on a moved line is the same alert ---------------------------
eq  "error key: line number ignored"   "$(script_error_key 'line 2126: echo: write error: Broken pipe')" "$(script_error_key 'line 2141: echo: write error: Broken pipe')"
no  "error key: other errors differ"   test "$(script_error_key 'line 9: x: unbound variable')" = "$(script_error_key 'line 9: y: unbound variable')"

# ---- discovery result fields: each half fills the other's blanks ----------------------------------
o=$(jq -r 'select(.type=="text") | .part.text' "$F/kilo-2026-11-09-212038-discover-campus-vlan-radius-lab.jsonl" | tail -1)
r=$(discovery_fields <<<"$o")
eq  "discovery: pr_body from body (21:35)" "[]" "$(jq -c .missing <<<"$r")"
eq  "discovery: same text"             "$(jq -r .body <<<"$o")" "$(jq -r .pr_body <<<"$r")"
eq  "discovery: body from pr_body"     "[]" "$(discovery_fields <<<'{"action":"pr","pr_title":"t","pr_body":"b"}' | jq -c .missing)"
eq  "discovery: nothing to use"        '["pr_title","pr_body","title","body"]' "$(discovery_fields <<<'{"action":"pr","reason":"r","pr_body":"  "}' | jq -c .missing)"
eq  "discovery: issue needs no pr text" "[]" "$(discovery_fields <<<'{"action":"issue","title":"t","body":"b"}' | jq -c .missing)"
eq  "discovery: action case/space"     'pr []' "$(discovery_fields <<<'{"action":" PR ","pr_title":"t","pr_body":"b"}' | jq -r '"\(.action) \(.missing|tojson)"')"
eq  "discovery: unknown action"        '["action"]' "$(discovery_fields <<<'{"action":"fix","title":"t","body":"b"}' | jq -c .missing)"
eq  "discovery: no action"             '["action"]' "$(discovery_fields <<<'{"reason":"r"}' | jq -c .missing)"
eq  "discovery: none needs nothing"    "[]" "$(discovery_fields <<<'{"action":"none","reason":"r"}' | jq -c .missing)"

# ---- config check: a bad setting stops the tick instead of changing what a limit means ---------------
eq  "config: the shipped config.sh is valid"   "" "$(config_errors)"
has "config: empty budget setting"             'WEEK_TARGET is "", not a whole number' "$(WEEK_TARGET=""; config_errors)"
has "config: unset setting"                    'MAX_RUNS_PER_DAY is "", not a whole number' "$(unset MAX_RUNS_PER_DAY; config_errors)"
has "config: target over 100"                  "WEEK_TARGET is 950, over 100" "$(WEEK_TARGET=950; config_errors)"
has "config: decimal"                          'DAILY_MAX is "1.5"' "$(DAILY_MAX=1.5; config_errors)"
has "config: hour out of range"                "WINDOW_END is 70, not an hour" "$(WINDOW_END=70; config_errors)"
has "config: bad time"                         'FREE_TIMEOUT is "30 min"' "$(FREE_TIMEOUT="30 min"; config_errors)"
has "config: bad merge method"                 'MERGE_METHOD is "fast"' "$(MERGE_METHOD=fast; config_errors)"
eq  "config: leading zero is fine"             "" "$(WINDOW_START=08; WINDOW_END=09; config_errors)"
tk() ( # a tick with a bad setting does no work at all
  DRY_RUN=1; DAILY_MAX=abc; rm -f "$W/tick_work" "$W/tick_notify"
  log() { :; }; notify() { echo "$1|$2" > "$W/tick_notify"; }; bot_version() { echo t; }
  getent() { return 0; }; apply_free_ranking() { echo ranked >> "$W/tick_work"; }; review_prs() { echo reviewed >> "$W/tick_work"; return 1; }
  tick >/dev/null 2>&1; echo "$(cat "$W/tick_work" 2>/dev/null)|$(cat "$W/tick_notify" 2>/dev/null)" )
eq  "config: a tick with a bad setting does nothing and alerts" "|critical|pr-autopilot: bad setting in config.sh" "$(tk)"

# ---- ntfy topic: kept in state/, not in the tracked config.sh --------------------------------------
nt() ( NTFY_TOPIC_FILE=$W/ntfy-topic; rm -f "$NTFY_TOPIC_FILE"; notify() { echo "$NTFY_TOPIC" > "$W/nt_sent"; }
  out=$(set_ntfy_topic <<<"$1" 2>&1); rc=$?; NTFY_TOPIC=old; load_ntfy_topic
  echo "$rc|$NTFY_TOPIC|$(stat -c %a "$NTFY_TOPIC_FILE" 2>/dev/null)|$( [[ $out == *"$2"* ]] && echo said)" )
eq  "ntfy: a pasted topic is saved privately and loaded" "0|my-topic_0123456789abcdef|600|said" "$(nt my-topic_0123456789abcdef "Sent a test alert")"
eq  "ntfy: a pasted topic is not echoed"       "" "$(NTFY_TOPIC_FILE=$W/ntfy-topic; notify() { :; }; set_ntfy_topic <<<"my-topic_0123456789abcdef" 2>&1 | $GREP -o 'my-topic_0123456789abcdef')"
eq  "ntfy: a bad topic is refused"             "1|old||said" "$(nt 'bad topic/..' "Nothing saved")"
has "ntfy: empty input makes a random topic"   "|600|said" "$(nt "" "shown once")"
eq  "ntfy: the random topic is long"           "45" "$(NTFY_TOPIC_FILE=$W/ntfy-topic; notify() { :; }; set_ntfy_topic <<<"" >/dev/null 2>&1; head -n 1 "$NTFY_TOPIC_FILE" | tr -d '\n' | wc -c)"
eq  "ntfy: a garbage file means no topic"      "" "$(NTFY_TOPIC_FILE=$W/ntfy-topic; echo 'x y; rm' > "$NTFY_TOPIC_FILE"; NTFY_TOPIC=old; load_ntfy_topic; echo "$NTFY_TOPIC")"
eq  "ntfy: no file keeps the config.sh value"  "old" "$(NTFY_TOPIC_FILE=$W/none; NTFY_TOPIC=old; load_ntfy_topic; echo "$NTFY_TOPIC")"
eq  "ntfy: config.sh no longer holds a topic"  "" "$($GREP -E '^ *NTFY_TOPIC=.*[A-Za-z0-9]' "$T/../config.sh")"

# ---- a fix that waits too long for an agent is handed over ------------------------------------------
wh() ( rm -rf "$STATE/waiting"; add_label() { echo "label $1#$2 $3 | $4" >> "$W/wh_out"; }; log() { :; }; rm -f "$W/wh_out"
  NOW=1000000; wait_handoff r 7 aaa "ahead of pace"                     # first sighting: start the clock
  NOW=$((1000000 + 23*3600)); wait_handoff r 7 aaa "ahead of pace"      # 23h: still waiting
  echo "23h:$(cat "$W/wh_out" 2>/dev/null)"
  NOW=$((1000000 + 23*3600)); wait_handoff r 7 bbb "ahead of pace"      # new commit: the clock restarts
  NOW=$((1000000 + 46*3600)); wait_handoff r 7 bbb "ahead of pace"      # 23h on the new commit
  echo "new:$(cat "$W/wh_out" 2>/dev/null)"
  NOW=$((1000000 + 48*3600)); wait_handoff r 7 bbb "ahead of pace"      # 25h on the new commit
  echo "25h:$(cat "$W/wh_out" 2>/dev/null)|$(ls "$STATE/waiting" | wc -l)" )
eq  "handoff: 24h without an agent hands the PR over, a new commit restarts the clock" \
    "23h: new: 25h:label r#7 autopilot-needs-human | no agent could take the next fix for 25h (ahead of pace)|0" "$(wh | tr '\n' ' ' | sed 's/ $//')"
eq  "handoff: 0 turns it off" "" "$(CLAUDE_WAIT_HOURS=0; rm -rf "$STATE/waiting"; add_label() { echo labelled; }; NOW=1; wait_handoff r 8 a x; NOW=999999999; wait_handoff r 8 a x)"
eq  "handoff: a dry run records nothing" "0" "$(DRY_RUN=1; rm -rf "$STATE/waiting"; wait_handoff r 9 a x; ls "$STATE/waiting" 2>/dev/null | wc -l)"
eq  "free agents are told not to prefix commands with cd" "1" "$($GREP -c 'Never start a command with cd' "$SRC")"

# ---- free model ranking: trial score as a prior, real-run record, ties spread over agents ----------
list_free_models() { printf '%s\n' agy:a1 agy:a2 agy:a3 kilo:k1 kilo:k2 vibe:v1 opencode:o1 opencode:bad; }
model_live_stats() { printf '%s\n' "kilo:k1 9 10" "opencode:o1 3 10"; }
jq -n --argjson now "$EPOCHSECONDS" '{"agy:a1","agy:a2","agy:a3","kilo:k2","vibe:v1"} | map_values({score:100,pass:true,unsafe:false,at:$now,v:2})
  + {"kilo:k1": {score:100,pass:true,unsafe:false,at:$now,v:2}, "opencode:o1": {score:100,pass:true,unsafe:false,at:$now,v:2},
     "opencode:bad": {score:100,pass:true,unsafe:true,at:$now,v:2}}' > "$MODEL_TRIALS"
eq  "ranking: record first, ties spread, weak and unsafe out" "kilo:k1 agy:a1 vibe:v1 agy:a2 kilo:k2 agy:a3" \
    "$(rank_free_models | cut -d' ' -f2 | tr '\n' ' ' | sed 's/ $//')"
FREE_AUTO=1 FREE_MAX_MODELS=4; FREE_LISTED=("opencode:o1"); apply_free_ranking
eq  "ranking: top FREE_MAX_MODELS in use"               "kilo:k1 agy:a1 vibe:v1 agy:a2" "${FREE_AGENTS[*]}"
echo $(( EPOCHSECONDS + 7 * 86400 )) > "$(cool_file agy:a1)"
apply_free_ranking
eq  "ranking: a model out of quota for days gives up its place" "kilo:k1 vibe:v1 agy:a2 kilo:k2" "${FREE_AGENTS[*]}"
echo $(( EPOCHSECONDS + 3600 )) > "$(cool_file agy:a1)"
apply_free_ranking
eq  "ranking: ...but not for an hour's cooldown"       "kilo:k1 agy:a1 vibe:v1 agy:a2" "${FREE_AGENTS[*]}"

# ---- trials: a model that never returns its JSON result is not used (2026-11-10 nemotron-3.5-lightning: 88) ----
( trial_task() { TT_PASS=true; TT_SECS=40; TT_LEAK=""; TT_EV=""; TT_JSON=${TJ[$2]}; TT_SCORE=${TS[$2]}; }
  log() { :; }; notify() { :; }; command() { return 0; }
  declare -A TJ TS; MODEL_TRIALS=$W/trial.json; echo '{}' > "$MODEL_TRIALS"
  TJ=([easy]=0 [hard]=0); TS=([easy]=85 [hard]=90); trial_model kilo:nj
  TJ=([easy]=1 [hard]=0); TS=([easy]=100 [hard]=90); trial_model kilo:half
  TJ=([easy]=1 [hard]=1); TS=([easy]=100 [hard]=100); trial_model kilo:full
  jq -r '"\(."kilo:nj".score) \(."kilo:nj".nojson) \(."kilo:half".score) \(."kilo:half".nojson) \(."kilo:full".score) \(."kilo:full".nojson)"' "$MODEL_TRIALS" > "$W/trial.out"
  list_free_models() { printf '%s\n' kilo:nj kilo:half kilo:full; }; model_live_stats() { :; }
  rank_free_models | cut -d' ' -f2 | tr '\n' ' ' > "$W/trial.rank"
  trial_candidates | tr '\n' ' ' > "$W/trial.now"
  jq --argjson now "$EPOCHSECONDS" 'map_values(.at = $now - 90000)' "$MODEL_TRIALS" > "$MODEL_TRIALS.t" && mv "$MODEL_TRIALS.t" "$MODEL_TRIALS"
  FREE_LISTED=(); trial_candidates | tr '\n' ' ' > "$W/trial.later" )
eq  "trial: no JSON on any task is capped"   "40 true 94 false 100 false" "$(cat "$W/trial.out")"
eq  "trial: the no-JSON model is not ranked" "kilo:full kilo:half " "$(cat "$W/trial.rank")"
eq  "trial: nothing retried the same day"    "" "$(cat "$W/trial.now")"
eq  "trial: the no-JSON model is retried after a day" "kilo:nj " "$(cat "$W/trial.later")"
# systemd runs ticks with SIGPIPE ignored: a loop cut short by `| head` got EPIPE on echo, and the
# "write error: Broken pipe" became a critical script-error alert (2026-11-09 21:20, fix29's head -n)
e=$(for i in 1 2 3 4 5; do (trap '' PIPE; FREE_MAX_MODELS=1; apply_free_ranking; echo "${FREE_AGENTS[*]}" >&3) 3>>"$W/rank1" 2>&1 >/dev/null; done)
eq  "ranking: no broken pipe with SIGPIPE ignored"     "" "$e"
eq  "ranking: FREE_MAX_MODELS=1 keeps only the best"   "kilo:k1" "$(sort -u "$W/rank1" | tr '\n' ' ' | sed 's/ $//')"; rm -f "$W/rank1"
rm -f "$(cool_file agy:a1)"
unset -f list_free_models model_live_stats

# ---- merge: a merged PR frees its slot in the same tick; a refused one doesn't --------------------
saved_fns=$(declare -f gh_w add_label fail merge_block_reasons)   # put back after these tests
gh_w() { [[ $GHW == ok ]] || { echo "X Pull request is not mergeable" >&2; return 1; }; }
add_label() { :; }; fail() { :; }; merge_block_reasons() { :; }
AUTO_MERGE=1 MERGE_METHOD=squash DRY_RUN=0; mkdir -p "$STATE/rounds" "$STATE/mergefail"
OPEN_COUNT=4; GHW=ok; echo 2 > "$STATE/rounds/r-1"; merge_pr r 1 abc >/dev/null 2>&1
eq  "merge: slot freed"                                 3 "$OPEN_COUNT"
eq  "merge: round count cleared"                        "" "$(cat "$STATE/rounds/r-1" 2>/dev/null)"
OPEN_COUNT=4; PARKED_COUNT=0; GHW=no; merge_pr r 2 def "sig" >/dev/null 2>&1
eq  "merge refused: still open"                         4 "$OPEN_COUNT"
eq  "merge refused: waits for you, slot freed"          1 "$PARKED_COUNT"
has "merge refused: remembered so it isn't retried each tick" "def" "$(cat "$STATE/mergefail/r-2" 2>/dev/null)"
unset -f gh_w add_label fail merge_block_reasons; eval "$saved_fns"

# ---- log pruning: old per-run transcripts go, day logs and recent runs stay ------------------------
for f in 2026-01-01.log kilo-2026-01-01-000000-fix-r-1.jsonl agy-2026-01-01-000000-trial-easy.jsonl.err deps-2026-01-01-000000-r.log; do
  echo x > "$LOGS/$f"; touch -d '40 days ago' "$LOGS/$f"; done
echo x > "$LOGS/kilo-new.jsonl"; touch -d '10 days ago' "$LOGS/kilo-new.jsonl"
RUN_LOG_KEEP_DAYS=30 prune_run_logs >/dev/null
eq  "prune: old runs gone, day log and recent run kept" "2026-01-01.log kilo-new.jsonl" "$(cd "$LOGS" && /usr/bin/ls | tr '\n' ' ' | sed 's/ $//')"

# ---- budget gate and engine choice (the plan is also used interactively: these must never let Claude run early) ----
# Nothing here may reach Claude or the network: those calls are recorded and fail the suite.
claude() { echo "claude $*" >> "$W/forbidden"; return 1; }
curl()   { echo "curl $*" >> "$W/forbidden"; return 1; }
notify() { echo "$4" >> "$W/notified"; }
probe_usage() { echo probe >> "$W/probes"; }          # a reading that fails: budget_ok must fail safe
rm -f "$W/forbidden" "$W/notified" "$W/probes" "$HERE/PAUSE"
NOW=$EPOCHSECONDS; TODAY=$(date +%F)
WEEK_TARGET=95 DAILY_MAX=12 FIVE_HOUR_MAX=60 MAX_RUNS_PER_DAY=10
usage() { jq -nc --argjson t "$NOW" --argjson f "$1" --argjson s "$2" --arg st "${3:-allowed}" \
  '{t:$t, status:$st, five:$f, seven:$s, seven_reset:($t + 302400)}' > "$STATE/usage.json"; }  # half the week left: pace 47.5%
in_window() { [[ $INWIN == 1 ]]; }
gate() { rm -f "$STATE/daystart-$TODAY"; [[ -n ${2:-} ]] && echo "$2" > "$STATE/daystart-$TODAY"; WHY=""; budget_ok >/dev/null 2>&1; echo "$?|$WHY"; }
INWIN=1; echo 0 > "$STATE/runs-$TODAY"
usage 0.20 0.30; eq "budget: under every limit"        "0|"  "$(gate x 0.30)"
usage 0.65 0.30; has "budget: 5h window too full"       "1|5-hour window at 65%" "$(gate x 0.30)"
usage 0.20 0.50; has "budget: weekly ahead of pace"     "1|weekly 50% is ahead of pace 47%" "$(gate x 0.45)"
usage 0.20 0.44; has "budget: daily max"                "1|already used 14% today" "$(gate x 0.30)"
usage 0.20 0.30 rejected; has "budget: plan limit"      "1|plan limit reached" "$(gate x 0.30)"
eq  "budget: no probe while a reading is fresh"         "" "$(cat "$W/probes" 2>/dev/null)"
jq -c '.t = 0' "$STATE/usage.json" > "$W/u" && mv "$W/u" "$STATE/usage.json"
has "budget: stale reading + failed probe = blocked"    "1|could not read plan usage (failing safe)" "$(gate x 0.30)"
rm -f "$W/probes"; usage 0.20 0.30
INWIN=0; has "budget: outside Claude hours"             "1|outside Claude hours" "$(gate x 0.30)"
INWIN=1; echo 10 > "$STATE/runs-$TODAY"
has "budget: MAX_RUNS_PER_DAY"                          "1|MAX_RUNS_PER_DAY reached" "$(gate x 0.30)"
echo 0 > "$STATE/runs-$TODAY"; touch "$HERE/PAUSE"
has "budget: PAUSE"                                     "1|PAUSE file present" "$(gate x 0.30)"
rm -f "$HERE/PAUSE"
eq  "budget: blocked gates never probe"                 "" "$(cat "$W/probes" 2>/dev/null)"
# the gate fails closed: before fix47 any jq error gave an empty answer, which meant "allowed"
usage 0.20 0.30
has "budget: daystart file empty"                       "0|" "$(: > "$STATE/daystart-$TODAY"; WHY=""; budget_ok >/dev/null 2>&1; echo "$?|$WHY")"
has "budget: daystart not a number = blocked"           "1|" "$(gate x garbage)"
has "budget: daystart null = blocked"                   "1|the usage reading or a budget setting is not a number" "$(gate x null)"
has "budget: WEEK_TARGET empty = blocked"               "1|" "$(WEEK_TARGET=""; gate x 0.30)"
has "budget: DAILY_MAX not a number = blocked"          "1|" "$(DAILY_MAX=abc; gate x 0.30)"
has "budget: FIVE_HOUR_MAX unset = blocked"             "1|" "$(unset FIVE_HOUR_MAX; gate x 0.30)"
jq -c 'del(.seven)' "$STATE/usage.json" > "$W/u" && mv "$W/u" "$STATE/usage.json"
has "budget: reading without the weekly number = blocked" "1|the usage reading or a budget setting is not a number" "$(gate x 0.30)"
echo '{"t":'"$NOW"',broken' > "$STATE/usage.json"
has "budget: unreadable reading = blocked"              "1|" "$(gate x 0.30)"
jq -nc --argjson t "$NOW" '{t:$t, status:"allowed", five:0.2, seven:0.97, seven_reset:($t - 86400)}' > "$STATE/usage.json"
has "budget: reset time in the past is not extra room"  "1|weekly 97% is ahead of pace 95%" "$(gate x 0.90)"
eq  "budget: only the unreadable reading was probed again" "probe" "$(cat "$W/probes" 2>/dev/null)"
rm -f "$W/probes"
usage 0.20 0.30

# choose_engine, with free_ready and budget_ok stubbed
eval "real_$(declare -f budget_ok)"
FREE_AGENTS=("kilo:m1" "agy:m2"); FREE_TRIES=2 FREE_MAX_ROUNDS=3 FREE_EXTRA_ROUNDS=1 MAX_FIX_ROUNDS=5
free_ready() { [[ " $READY " == *" $1 "* ]]; }
budget_ok() { echo b >> "$W/budget_calls"; [[ $BUDGET == ok ]] || { WHY="stub budget blocked"; return 1; }; }
printf '%s\n' "2026-11-09 10:00:00   starting kilo (m1, free): fix-r-1" "2026-11-09 10:05:00   starting agy (m3, free): fix-r-2" > "$LOGS/2026-11-09.log"
eq  "task_models from the logs"                         "kilo:m1" "$(task_models fix-r-1)"
pick() { local k=$1 r=$2; rm -f "$W/budget_calls"; echo "${FAILN:-0}" > "$STATE/freefail/$k"; ENGINE=""; WHY=""
  choose_engine "$k" "$r" >/dev/null 2>&1; echo "$?|$ENGINE|$( [[ -e $W/budget_calls ]] && echo budget)"; }
mkdir -p "$STATE/freefail"; printf 'fake-bot-token\n' > "$CLAUDE_TOKEN_FILE"
READY="kilo:m1 agy:m2" BUDGET=ok
eq  "engine: free model first, budget untouched"        "0|kilo:m1|" "$(pick fix-r-1 1)"
eq  "engine: free trailer"                              "Generated-By: pr-autopilot (kilo, m1)" "$(choose_engine fix-r-1 1 >/dev/null 2>&1; echo "$TRAILER")"
FAILN=2; eq "engine: Claude after FREE_TRIES failures" "0|claude|budget" "$(pick fix-r-1 2)"
FAILN=0; eq "engine: Claude for rounds past FREE_MAX_ROUNDS" "0|claude|budget" "$(pick fix-r-1 4)"
BUDGET=no
FAILN=2; eq "engine: Claude blocked -> a free model new to the PR" "0|agy:m2|budget" "$(pick fix-r-1 2)"
eq  "engine: ...up to FREE_MAX_ROUNDS+FREE_EXTRA_ROUNDS" "0|agy:m2|budget" "$(pick fix-r-1 4)"
eq  "engine: the last round stays Claude's"             "1||budget" "$(pick fix-r-1 5)"
eq  "engine: ...even with more extra rounds"           "1||budget" "$(FREE_EXTRA_ROUNDS=3 pick fix-r-1 5)"
READY="kilo:m1"; eq "engine: no new free model -> waits" "1||budget" "$(pick fix-r-1 2)"
READY="kilo:m1 agy:m2"; eq "engine: no extra free rounds for discovery" "1||budget" "$(pick discover-r 1)"
FAILN=0; READY=""; BUDGET=ok
eq  "engine: FREE_ONLY never reaches the budget"        "1||" "$(FREE_ONLY=1 pick fix-r-1 1)"
why() { local k=$1 r=$2; echo "${FAILN:-0}" > "$STATE/freefail/$k"; ENGINE=""; WHY=""; choose_engine "$k" "$r" >/dev/null 2>&1; echo "$ENGINE|$WHY"; }
READY="kilo:m1 agy:m2"; FAILN=2
eq  "engine: a tick's extra fix also gets a free model new to the PR" "0|agy:m2|" "$(FREE_ONLY=1 pick fix-r-1 2)"
eq  "engine: ...not for the last round, and no budget"  "1||" "$(FREE_ONLY=1 pick fix-r-1 5)"
eq  "engine: extra fix waits: outside Claude hours"     "|outside Claude hours ${WINDOW_START}:00-${WINDOW_END}:00" "$(in_window() { return 1; }; FREE_ONLY=1 why fix-r-1 5)"
eq  "engine: extra fix waits: Claude's one fix a tick"  "|Claude takes only one fix per tick" "$(in_window() { return 0; }; FREE_ONLY=1 why fix-r-1 5)"
READY=""; FAILN=0
eq  "engine: extra fix waits: free models cooling"      "|no free model is ready (all cooling down)" "$(FREE_ONLY=1 why fix-r-1 1)"
touch "$HERE/PAUSE"; READY="kilo:m1"
eq  "engine: PAUSE stops free models too"               "1||" "$(pick fix-r-1 1)"
rm -f "$HERE/PAUSE"; READY=""; : > "$CLAUDE_TOKEN_FILE"
eq  "engine: no bot token -> no Claude, no budget"      "1||" "$(pick fix-r-1 1)"
has "engine: ...and it tells you"                       no-claude-token "$(cat "$W/notified" 2>/dev/null)"

# ---- PR state parser (load_prs) on a real snapshot: 2026-11-09 20:20 ------------------------
# anticheat-arm64#138: CodeRabbit answered both bot declines with "I acknowledge your decision to
# accept ..." - nothing to reconsider (the 20:20 tick spent a free round on it and counted a failure).
# The same reply with a correction ("For clarity ...", as on rhythm-linux#8) still reopens the thread.
gh() { if [[ $1 == api && $2 == graphql ]]; then cat "$PRS_RAW"; else [[ "$*" == "auth token" ]] && echo "fakeGhToken0123456789abcdefXYZ"; fi; }
reopened() { PRS_RAW=$1 load_prs 2>/dev/null | jq -r --arg r "$2" --argjson n "$3" '.[] | select(.repo == $r and .n == $n) | [.threads[] | select(.reply)] | length'; }
P=$F/prs-2026-11-09-2020.raw.json
eq  "prs: 3 bot PRs parsed"                            3 "$(PRS_RAW=$P load_prs 2>/dev/null | jq length)"
eq  "prs: an acknowledged decline is not reopened"     0 "$(reopened "$P" anticheat-arm64 138)"
jq '(.data.search.nodes[].reviewThreads.nodes[].comments.nodes[] | select(.body | test("I acknowledge your decision"))).body
      |= sub("I acknowledge"; "For clarity, the finding is about the reload, not the lock. I acknowledge")' "$P" > "$W/prs-clarity.json"
eq  "prs: an acknowledgement with a correction reopens" 2 "$(reopened "$W/prs-clarity.json" anticheat-arm64 138)"
jq '(.data.search.nodes[].reviewThreads.nodes[].comments.nodes[] | select(.body | test("I acknowledge your decision"))).body
      |= sub("I acknowledge your decision[^.]*\\."; "The race is still reachable; please reconsider.")' "$P" > "$W/prs-pushback.json"
eq  "prs: a pushback reopens"                          2 "$(reopened "$W/prs-pushback.json" anticheat-arm64 138)"
mkdir -p "$STATE/reopened"; jq -r '.data.search.nodes[] | select(.number == 138) | .reviewThreads.nodes[] | select(.comments.nodes | any(.body | startswith("Not applying this:"))) | .id' "$P" > "$STATE/reopened/anticheat-arm64-138"
eq  "prs: ...but only once"                            0 "$(reopened "$W/prs-pushback.json" anticheat-arm64 138)"
rm -rf "$STATE/reopened"
# review_prs: a clean PR in a repo without CI waits for the owner and frees its work slot, like one
# that needs an approving review (2026-11-09 22:05: two no-CI repos got discovery PRs; status counted
# such PRs as parked, the tick didn't). A young no-CI PR is still active.
slots() ( # <pr-json list>  -> "open parked" after review_prs, in dry run
  DRY_RUN=1; NOW=$EPOCHSECONDS; LIST=$1
  load_prs() { printf '%s' "$LIST"; }
  review_prs >/dev/null 2>&1; echo "$OPEN_COUNT $PARKED_COUNT"
)
one=$(PRS_RAW=$P load_prs 2>/dev/null | jq -c --argjson t $((EPOCHSECONDS - 3600)) '[.[] | select(.repo == "rhythm-linux")][0]
      | .ci = "none" | .checks = [] | .failed_checks = [] | .cr_reviewed_head = true | .cr_clean = true | .threads = []
      | .cr_body_issues = "" | .claude_check = false | .labels = ["autopilot"] | .mergeable = "MERGEABLE" | .head_time = $t')
eq  "no CI, clean: parked"                             "1 1" "$(slots "[$one]")"
young=$(jq -c --argjson t $((EPOCHSECONDS - 600)) '.n = 99 | .head_time = $t' <<<"$one")
eq  "no CI, 10 min old: still active"                  "2 1" "$(slots "[$one,$young]")"
eq  "AUTO_MERGE=0, clean with CI: parked"              "1 1" "$(gh() { echo 0; }; AUTO_MERGE=0 slots "[$(jq -c '.ci = "passed"' <<<"$one")]")"   # gh: 0 commits behind
# a PR labelled needs-human in this tick frees its slot now, not next tick (CI pending for 7h)
eq  "labelled needs-human now: parked"                 "1 1" "$(slots "[$(jq -c --argjson t $((EPOCHSECONDS - 25200)) '.ci = "pending" | .head_time = $t' <<<"$one")]")"
al() ( # add_label with GitHub refusing -> "rc parked notified"
  DRY_RUN=0; PARKED_COUNT=0; gh() { return 1; }; : > "$W/notified"
  add_label r 5 "$LABEL-needs-human" "why" >/dev/null 2>&1; echo "$? $PARKED_COUNT $(wc -l < "$W/notified")"
)
eq  "label refused: no alert, not parked"              "1 0 0" "$(al)"
# the CodeRabbit wait names the latest limit: here the 5-minute wait after a commit, not cr_next (past)
fresh=$(jq -c --argjson t $((EPOCHSECONDS - 120)) '.ci = "passed" | .cr_reviewed_head = false | .cr_clean = false | .cr_seen = true | .head_time = $t' <<<"$one")
has "CodeRabbit wait: the real next time"              "next request allowed $(date -d "@$((EPOCHSECONDS + 180))" +%H:%M)" "$(echo 0 > "$STATE/cr_next"; rm -f "$STATE/crreq/rhythm-linux-$(jq .n <<<"$one")"; DRY_RUN=1 NOW=$EPOCHSECONDS; LIST="[$fresh]"; load_prs() { printf '%s' "$LIST"; }; review_prs 2>&1 >/dev/null)"
has "no CI, clean: logged"                             "labelled ready, not merging; waiting for you" "$(DRY_RUN=1 NOW=$EPOCHSECONDS; LIST="[$one]"; load_prs() { printf '%s' "$LIST"; }; review_prs 2>&1 >/dev/null)"
gh() { [[ "$*" == "auth token" ]] && echo "fakeGhToken0123456789abcdefXYZ"; }

# ---- a branch update that fails waits for the owner like a refused merge -------------------------
lp() ( # <update-branch rc> [asked secs ago]  -> "parked mergefail-record"
  DRY_RUN=0; NOW=$EPOCHSECONDS; PARKED_COUNT=0; UPD_RC=$1; rm -f "$STATE/mergefail/r-7" "$STATE/mergefail/r-7.why" "$STATE/updated/r-7"
  [[ -n ${2:-} ]] && echo "abc123 100 $((NOW - $2))" > "$STATE/updated/r-7"
  gh() { case "$*" in *compare*) echo 3 ;; *update-branch*) return "$UPD_RC" ;; *) return 0 ;; esac; }
  gh_w() { gh "$@"; }; add_label() { :; }; fail() { :; }
  land_pr r 7 abc123 main 100 SIG >/dev/null 2>&1
  echo "$PARKED_COUNT $(cat "$STATE/mergefail/r-7" 2>/dev/null)"
)
eq  "update refused: parked, no retry for now"         "1 abc123 SIG" "$(lp 1)"
eq  "update never made: parked"                        "1 abc123 SIG" "$(lp 0 4000)"
eq  "update asked 10 min ago: waits, active"           "0 " "$(lp 0 600)"
eq  "update accepted: active"                          "0 " "$(lp 0)"

# ---- discovery: GitHub not answering for the repo gives back the scan and the day's slot ----------
dv() ( # -> "rc discoveries scanned?"
  DRY_RUN=0; NOW=$EPOCHSECONDS; echo 2 > "$STATE/discoveries-$TODAY"; mkdir -p "$STATE/scanned"; rm -f "$STATE/scanned/r"
  gh() { return 1; }; prep_worktree() { echo "prep $*" >> "$W/forbidden"; return 1; }; fail() { echo "fail $*" >> "$W/forbidden"; }
  discover r >/dev/null 2>&1; echo "$? $(discoveries_today) $([[ -e $STATE/scanned/r ]] && echo yes || echo no)"
)
eq  "discovery, repo unreadable: slot and scan back"   "1 2 no" "$(dv)"
# a failed free attempt gives the day's slot back too (it opened nothing); Claude's keeps it
df() ( # <engine> <agent output> -> "discoveries scanned? freefail"
  DRY_RUN=0; NOW=$EPOCHSECONDS; ENGINE=$1; echo 2 > "$STATE/discoveries-$TODAY"; mkdir -p "$STATE/scanned" "$STATE/freefail"; rm -f "$STATE/scanned/r" "$STATE/freefail/discover-r"
  gh() { [[ "$1 $2" == "repo view" ]] && echo '{"defaultBranchRef":{"name":"main"},"hasDiscussionsEnabled":false}'; return 0; }
  prep_worktree() { WT_DIR=$W; }; prep_deps() { :; }; ensure_labels() { :; }; log() { :; }
  AGENT_OUT=$2; run_agent() { cat >/dev/null; printf '%s' "$AGENT_OUT"; }
  discover r >/dev/null 2>&1; echo "$(discoveries_today) $([[ -e $STATE/scanned/r ]] && echo yes || echo no) $(cat "$STATE/freefail/discover-r" 2>/dev/null)"
)
eq  "discovery, free attempt failed: slot back, counted" "2 no 1" "$(df kilo:m1 "")"
eq  "discovery, free result unusable: slot back"         "2 no 1" "$(df kilo:m1 '{"action":"pr","reason":"r"}')"
eq  "discovery, Claude attempt failed: slot used"        "3 no " "$(df claude "")"
eq  "discovery, nothing to do: slot used, repo scanned"  "3 yes " "$(df kilo:m1 '{"action":"none","reason":"r"}')"
rm -f "$STATE/freefail/discover-r" "$STATE/scanned/r"
# pick_repo: a repo name with a dot is not a regex (a.b must not count as busy because axb is)
pr_dot() ( NOW=$EPOCHSECONDS; printf 'a.b\nzz\n' > "$STATE/repos.txt"; rm -rf "$STATE/scanned"; mkdir -p "$STATE/scanned"
  echo '{"data":{"search":{"nodes":[{"repository":{"name":"axb"}}]}}}' > "$STATE/prs.raw.json"; pick_repo )
eq  "pick_repo: dotted name is literal"                "a.b" "$(pr_dot)"
rm -f "$STATE/prs.raw.json" "$STATE/repos.txt"

# ---- status: a CodeRabbit time already past reads "now"; the next discovery says why it waits ------
st() ( # <open-prs-json> <discoveries today> <cr_next epoch>
  NOW=$EPOCHSECONDS; LIST=$1; echo "$2" > "$STATE/discoveries-$TODAY"; echo "$3" > "$STATE/cr_next"
  load_prs() { printf '%s' "$LIST"; }; apply_free_ranking() { :; }; night_report() { :; }; refresh_repos() { :; }
  FREE_AGENTS=(); printf 'repoA\nrepoB\n' > "$STATE/repos.txt"; rm -rf "$STATE/scanned" "$STATE/prs.raw.json"
  show_status 2>/dev/null
)
pr() { jq -nc --arg l "${1:-}" '{repo:"r", n:1, ci:"passed", cr_clean:false, cr_reviewed_head:true, threads:[], head_time:0, labels:(["autopilot"] + (if $l == "" then [] else [$l] end))}'; }
s=$(st "[$(pr)]" 0 1)
has "status: past CodeRabbit time is now"              "CodeRabbit next request allowed: now" "$s"
has "status: next discovery, nothing in the way"       "repoA                        eligible now  <- next"$'\n' "$s"
eq  "status: second repo"                              "  repoB                        eligible now" "$(tail -1 <<<"$s")"
has "status: daily discoveries used"                   "<- next (tomorrow: today's $MAX_DISCOVERIES_PER_DAY scans are used)" "$(st "[$(pr)]" "$MAX_DISCOVERIES_PER_DAY" 1)"
four="[$(pr),$(pr),$(pr),$(pr)]"
has "status: slots full"                               "<- next (when a work slot frees up)" "$(st "$four" 0 1)"
has "status: a ready PR frees its slot"                "<- next"$'\n' "$(st "[$(pr),$(pr),$(pr),$(pr autopilot-ready)]" 0 1)"
has "status: future CodeRabbit time shown"             "allowed: $(date -d "@$((EPOCHSECONDS + 7200))" '+%F %H:%M')" "$(st "[]" 0 $((EPOCHSECONDS + 7200)))"
rm -f "$STATE/cr_next" "$STATE/discoveries-$TODAY" "$STATE/repos.txt"


# ---- worktrees: one made from the bot clone moves to your clone once you have one ----------------
G=$W/gitwt; [[ -d $G ]] && find "$G" -mindepth 1 -delete; mkdir -p "$G"
wt() ( # <repo> <ref>  -> prep_worktree in a scratch setup where github.com/$OWNER/x is the bare repo $G/o.git
  export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_2="url.$G/o.git.insteadOf" GIT_CONFIG_VALUE_2="https://github.com/$OWNER/x.git"
  REPOS=$G/repos WORKTREES=$G/wts; mkdir -p "$REPOS" "$WORKTREES"
  prep_worktree "$1" "$2" >/dev/null 2>&1 && echo "$(git -C "$WT_DIR" log -1 --format=%s) $(git -C "$WT_DIR" rev-parse --path-format=absolute --git-common-dir)"
)
gc() { git -C "$G/src" -c user.name=t -c user.email=t@localhost "$@"; }
( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q -b main "$G/src" && echo a > "$G/src/f" && gc add f && gc commit -qm A
  git clone -q --bare "$G/src" "$G/o.git" ) >/dev/null 2>&1
: > "$STATE/clones.tsv"                                        # no local clone yet: the bot clones it
eq  "worktree: bot clone"                              "A $G/repos/x/.git" "$(wt x main)"
( export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  echo b > "$G/src/f" && gc commit -qam B && gc push -q "$G/o.git" main
  git clone -q "$G/o.git" "$G/mine" ) >/dev/null 2>&1
printf 'x\t%s\torigin\n' "$G/mine" > "$STATE/clones.tsv"      # now you have a clone
eq  "worktree: moves to your clone, latest commit"     "B $G/mine/.git" "$(wt x main)"
eq  "worktree: reused after that"                      "B $G/mine/.git" "$(wt x main)"
rm -f "$STATE/clones.tsv"

# ---- version: the fixN tag install.sh made, +commits to the bot after it, -dirty for uncommitted bot edits ----
V=$W/vrepo; [[ -d $V ]] && find "$V" -mindepth 1 -delete; mkdir -p "$V" "$W/nogit"
eq  "version: not a repo"              unknown "$(GIT_CEILING_DIRECTORIES=$W bot_version "$W/nogit")"
( cd "$V" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q && git config user.name t && git config user.email t@localhost
  echo a > autopilot.sh && echo c > config.sh && echo r > README.md && git add -A && git commit -qm one ) >/dev/null 2>&1
eq  "version: no tag yet, short hash"  "$(git -C "$V" rev-parse --short HEAD)" "$(bot_version "$V")"
git -C "$V" tag -a fix7 -m fix7
eq  "version: on the tag"              fix7 "$(bot_version "$V")"
echo b > "$V/autopilot.sh"
eq  "version: hand-edited is dirty"    fix7-dirty "$(bot_version "$V")"
git -C "$V" -c user.name=t -c user.email=t@localhost commit -qam two
eq  "version: commits after the tag"   fix7+1 "$(bot_version "$V")"
echo s > "$V/README.md"
eq  "version: other files not dirty"   fix7+1 "$(bot_version "$V")"
git -C "$V" -c user.name=t -c user.email=t@localhost commit -qam docs
eq  "version: a docs commit doesn't count" fix7+1 "$(bot_version "$V")"
echo d > "$V/config.sh"
eq  "version: config edit is dirty"    fix7+1-dirty "$(bot_version "$V")"
eq  "version: never writes the index"  "" "$(find "$V/.git" -name index.lock)"
eval "$(declare -f real_budget_ok | sed '1s/real_budget_ok/budget_ok/')"
rr() ( # <gh output> <gh rc>  -> refresh_repos rc, then repos.txt
  GH_OUT=$1 GH_RC=$2; gh() { [[ -n $GH_OUT ]] && printf '%s\n' "$GH_OUT"; return "$GH_RC"; }
  printf 'old1\nold2\n' > "$STATE/repos.txt"; refresh_repos; echo "rc=$? $(tr '\n' ' ' < "$STATE/repos.txt")"
)
eq  "repo list: replaced"              "rc=0 new1 new2 " "$(rr $'new1\nnew2' 0)"
eq  "repo list: gh failed, kept"       "rc=1 old1 old2 " "$(rr "" 1)"
eq  "repo list: empty answer, kept"    "rc=1 old1 old2 " "$(rr "" 0)"
dg() ( # <log lines>  -> the daily digest's body
  DIGEST_HOUR=0; DRY_RUN=0; rm -f "$STATE/digest" "$STATE/usage.json" "$STATE/prs.raw.json"
  gh() { :; }; night_report() { :; }; notify() { printf '%s' "$3"; }
  printf '%s\n' "$1" | sed "s/^/$(date '+%F %T') /" > "$LOGS/$TODAY.log"
  daily_digest 2>/dev/null
)
d=$(dg '  starting kilo (kilo/x:free, free): fix-r-1
  starting opencode (opencode/y, free): discover-r
  starting kilo (kilo/x:free, free): trial-easy
  starting kilo (kilo/x:free, free): trial-hard
  starting Claude (fix): fix-r-2')
has "digest: trials counted apart"     "Agent runs: 1 Claude, 2 free (+2 idle-time model trials);" "$d"
has "digest: no trials, no mention"    "Agent runs: 0 Claude, 1 free; 0 fix pushes" "$(dg '  starting kilo (kilo/x:free, free): fix-r-1')"
eq  "nothing reached Claude or the network"             "" "$(cat "$W/forbidden" 2>/dev/null)"

echo "$PASS passed, ${#FAILS[@]} failed  ($SRC)"
for f in "${FAILS[@]}"; do echo "  FAIL: $f"; done
(( ${#FAILS[@]} == 0 ))
