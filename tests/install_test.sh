#!/usr/bin/env bash
# Tests for install.sh in a scratch repo: a fake autopilot.sh, a fake tests/run.sh (FAKE_TESTS=fail
# makes it fail) and a systemctl stub (FAKE_STATE). Never touches the live bot. Free: no network.
set -uo pipefail
T=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); R=$T/.work/inst
PASS=0; FAILS=()
eq()  { if [[ $2 == "$3" ]]; then PASS=$((PASS+1)); else FAILS+=("$1: expected [$2], got [${3:0:300}]"); fi; }
has() { if [[ $3 == *"$2"* ]]; then PASS=$((PASS+1)); else FAILS+=("$1: [$2] not in [${3:0:300}]"); fi; }

[[ -d $R ]] && find "$R" -mindepth 1 -delete
mkdir -p "$R/tests" "$R/bin" "$R/c"
cp "$T/../install.sh" "$R/install.sh"
ver() { printf '#!/bin/bash\n# %s\nmain() { echo %s; }\nmain "$@"; exit $?\n' "$1" "$1"; }
ver v1 > "$R/autopilot.sh"; chmod 755 "$R/autopilot.sh"
printf '#!/bin/bash\n[[ ${FAKE_TESTS:-} == fail ]] && { echo "1 failed"; exit 1; }\necho "9 passed, 0 failed"\n' > "$R/tests/run.sh"
printf '#!/bin/bash\necho "${FAKE_STATE:-inactive}"\n' > "$R/bin/systemctl"
chmod 755 "$R/tests/run.sh" "$R/bin/systemctl"
printf 'state/\n*.new\nc/\nmsg\n' > "$R/.gitignore"
echo 'X=1' > "$R/config.sh"
cd "$R" || exit 1
export PATH=$R/bin:$PATH GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q && git config user.name test && git config user.email test@localhost
git add -A && git commit -qm init && git tag -a fix1 -m fix1
echo "test install" > "$R/msg"
inst() { ./install.sh "$@" 2>&1; }

ver v2 > c/fix2.sh
out=$(FAKE_TESTS=fail inst c/fix2.sh msg); eq "failing tests: refused" v1 "$(./autopilot.sh)"
has "failing tests: says so"         "tests failed" "$out"
eq  "failing tests: no tag"          fix1 "$(git tag | tr '\n' ' ' | xargs)"
out=$(FAKE_STATE=active inst c/fix2.sh msg); eq "tick running: refused" v1 "$(./autopilot.sh)"
has "tick running: says so"          "a tick is running" "$out"
ver v9 > c/fix9.sh
has "wrong fixN name: refused"       "next tag is fix2" "$(inst c/fix9.sh msg)"
cp autopilot.sh c/same.sh
has "same file: refused"             "same as the live" "$(inst c/same.sh msg)"
echo 'X=2' > config.sh
has "unstaged change: refused"       "unstaged changes in: config.sh" "$(inst c/fix2.sh msg)"
eq  "unstaged change: not installed" v1 "$(./autopilot.sh)"
has "check mode: unstaged refused"   "unstaged changes in: config.sh" "$(inst --check c/fix2.sh)"
git add config.sh                                  # a staged companion goes into the same commit
echo fixture > new-fixture
has "untracked file: refused"        "untracked files: new-fixture" "$(inst c/fix2.sh msg)"
has "check mode: untracked refused"  "untracked files: new-fixture" "$(inst --check c/fix2.sh)"
eq  "untracked file: not installed"  v1 "$(./autopilot.sh)"
rm new-fixture
has "check mode: passes"             "would install as fix2" "$(inst --check c/fix2.sh)"
eq  "check mode: changes nothing"    v1 "$(./autopilot.sh)"
out=$(inst c/fix2.sh msg)
has "install: reported"              "fix2 installed" "$out"
eq  "install: live file replaced"    v2 "$(./autopilot.sh)"
eq  "install: executable kept"       755 "$(stat -c %a autopilot.sh)"
eq  "install: backup of v1"          v1 "$(bash state/autopilot.sh.bak1)"
eq  "install: tagged"                fix2 "$(git describe --match 'fix[0-9]*')"
eq  "install: companion committed"   "autopilot.sh config.sh" "$(git show --name-only --format= HEAD | sort | xargs)"
eq  "install: tree clean"            "" "$(git status --porcelain --untracked-files=no)"
eq  "install: no temp file left"     "" "$(ls ./*.new 2>/dev/null)"

echo '# edited by hand' >> autopilot.sh
has "hand-edited live: refused"      "aren't committed" "$(inst --rollback fix1 msg)"
git checkout -q autopilot.sh
out=$(FAKE_TESTS=fail inst --rollback fix1)        # rollbacks skip the tests
eq  "rollback: v1 is live again"     v1 "$(./autopilot.sh)"
eq  "rollback: tagged as next"       fix3 "$(git describe --match 'fix[0-9]*')"
has "rollback: default message"      "Roll back to fix1" "$(git log -1 --format=%s)"
eq  "rollback: backup of v2"         v2 "$(bash state/autopilot.sh.bak2)"
eq  "rollback: no temp file left"    "" "$(ls ./*.new 2>/dev/null)"
has "rollback: unknown tag refused"  "no tag fix99" "$(inst --rollback fix99)"

echo "$PASS passed, ${#FAILS[@]} failed  (install.sh)"
for f in "${FAILS[@]}"; do echo "  FAIL: $f"; done
(( ${#FAILS[@]} == 0 ))
