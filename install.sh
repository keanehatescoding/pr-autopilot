#!/usr/bin/env bash
# Install a new autopilot.sh: test it, back up the live one, swap it in atomically, commit, tag fixN.
#   install.sh CANDIDATE MESSAGE_FILE        the normal install
#   install.sh --rollback fixN [MESSAGE_FILE] put fixN's autopilot.sh back (as a new install, next tag)
#   install.sh --check CANDIDATE             run the checks only; nothing changes
# Stage companion changes first (git add tests/run.sh tests/fixtures/... config.sh): they go into
# the same commit. It refuses when the tests fail, a tick is running, the live autopilot.sh has
# uncommitted edits, a tracked file has unstaged changes, an untracked file isn't ignored (a fixture
# the tests used but the commit would miss), or the candidate is named fixN.sh for a different N
# than the next tag. --check runs every one of these. A rollback skips the tests: an older version
# fails newer tests.
# The running bot logs its version on every tick: "=== tick [fix31]" (see `autopilot.sh version`).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); cd "$HERE"
SVC=${PR_AUTOPILOT_SERVICE:-pr-autopilot.service}
die() { echo "install: $*" >&2; exit 1; }
tmpmsg=
trap 'rm -f "$HERE/autopilot.sh.new" ${tmpmsg:+"$tmpmsg"}' EXIT   # never leave a half-made install behind
usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

mode=install rollback= msg= cand=
case "${1:-}" in
  --rollback) mode=rollback; rollback=${2:-}; msg=${3:-}; [[ $rollback =~ ^fix[0-9]+$ ]] || usage ;;
  --check)    mode=check; cand=${2:-}; [[ -n $cand ]] || usage ;;
  -*|"")      usage ;;
  *)          cand=$1; msg=${2:-}; [[ -n $msg ]] || usage ;;
esac

[[ $(git rev-parse --show-toplevel 2>/dev/null) == "$HERE" ]] || die "$HERE is not the top of a git repo"
next=$(( $(git tag -l 'fix[0-9]*' | sed 's/^fix//' | /usr/bin/grep -E '^[0-9]+$' | sort -n | tail -1 || true) + 1 ))
[[ $next -gt 1 ]] || die "no fixN tags yet; tag the current install first (git tag -a fixN -m ...)"
tag=fix$next

state() { systemctl --user show -p ActiveState --value "$SVC" 2>/dev/null || echo unknown; }
idle() { local s; s=$(state); [[ $s == inactive || $s == failed ]] || { echo "install: $SVC is $s (a tick is running); try again after it" >&2; return 1; }; }

if [[ $mode == rollback ]]; then
  git rev-parse -q --verify "refs/tags/$rollback" >/dev/null || die "no tag $rollback"
  cand=autopilot.sh.new
  git show "$rollback:autopilot.sh" > "$cand"
else
  [[ -f $cand ]] || die "no such file: $cand"
  b=$(basename "$cand")
  [[ $b =~ ^fix([0-9]+)\.sh$ && fix${BASH_REMATCH[1]} != "$tag" ]] && die "the candidate is named $b but the next tag is $tag"
fi
bash -n "$cand" || die "syntax error in $cand"
[[ $(tail -1 "$cand") == 'main "$@"; exit $?' ]] || die "$cand does not end in the main call"
cmp -s "$cand" autopilot.sh && die "the candidate is the same as the live autopilot.sh"
git diff --quiet HEAD -- autopilot.sh || die "the live autopilot.sh has changes that aren't committed; commit or restore them first"
git diff --quiet || die "unstaged changes in: $(git diff --name-only | tr '\n' ' ')(git add what belongs to this install, restore the rest)"
untracked=$(git ls-files --others --exclude-standard | head -5 | tr '\n' ' ')
[[ -z $untracked ]] || die "untracked files: ${untracked}(git add what belongs to this install; delete or ignore the rest)"

if [[ $mode != rollback ]]; then
  echo "install: running tests/run.sh on $cand"
  tests/run.sh "$(realpath "$cand")" | tail -15 || die "tests failed; nothing installed"
fi
if [[ $mode == check ]]; then idle && echo "install: checks passed; it would install as $tag"; exit; fi

[[ -n $msg ]] || { tmpmsg=$(mktemp); msg=$tmpmsg; printf 'Roll back to %s\n' "$rollback" > "$msg"; }
[[ -s $msg ]] || die "empty or missing commit message file: $msg"
idle

mkdir -p state
n=$(( $(for f in state/autopilot.sh.bak*; do [[ -e $f ]] && echo "${f##*.bak}"; done | /usr/bin/grep -E '^[0-9]+$' | sort -n | tail -1 || true) + 1 ))
bak=state/autopilot.sh.bak$n
cp -p autopilot.sh "$bak"
restore() { cp -p "$bak" autopilot.sh.new && mv autopilot.sh.new autopilot.sh; }
[[ $cand -ef autopilot.sh.new ]] || cp "$cand" autopilot.sh.new
chmod --reference=autopilot.sh autopilot.sh.new && mv autopilot.sh.new autopilot.sh   # atomic: a starting tick reads old or new, never half
bash -n autopilot.sh || { restore; die "the installed file failed its syntax check; put $bak back"; }

git add autopilot.sh
git commit -q -F "$msg" || { restore; git reset -q HEAD -- autopilot.sh; die "commit failed; put $bak back"; }
git tag -a "$tag" -m "$tag: installed $(date '+%F %T')$([[ $mode == rollback ]] && echo ", a rollback to $rollback"); previous version in $bak"
echo "install: $tag installed ($(git rev-parse --short HEAD)); previous version in $bak"
echo "install: the next tick logs \"=== tick [$tag]\"; roll back with: $0 --rollback fix$((next - 1))"
