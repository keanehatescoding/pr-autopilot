#!/usr/bin/env bash
# publish.sh: put the current code on the public GitHub repo as ONE new snapshot commit.
#
# The local history (branch main, the fixN tags) never leaves this machine: old commits hold
# things that must stay private. Only the branch "public" is pushed, as "main" on GitHub; each
# publish adds one commit there with the files exactly as they are committed here now.
# state/, logs/, repos/ and worktrees/ are never committed, so they are never published.
#
#   ./publish.sh            scan, then publish the committed code
#   ./publish.sh --check    scan only; publish nothing
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); cd "$HERE"
REMOTE=public
GREP=/usr/bin/grep

git remote get-url "$REMOTE" >/dev/null 2>&1 || { echo "publish: no git remote named '$REMOTE'"; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "publish: there are uncommitted or untracked files; commit them first (git status)"; exit 1; }

# 1. nothing secret in what would be published
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git archive HEAD | tar -x -C "$tmp"
bad=0
if command -v gitleaks >/dev/null; then
  gitleaks detect --no-git --no-banner --redact -c "$HERE/.gitleaks.toml" -s "$tmp" >"$tmp.leaks" 2>&1 || { echo "publish: gitleaks found something:"; tail -n 30 "$tmp.leaks"; bad=1; }
  rm -f "$tmp.leaks"
else
  echo "publish: gitleaks is not installed; only the bot's own secrets are checked"
fi
# the bot's own secrets (state/) must not appear in any tracked file
while IFS= read -r -d '' f; do
  s=$(head -n 1 "$f" 2>/dev/null | tr -d '\r\n'); s=${s#*=}
  (( ${#s} >= 12 )) || continue
  if $GREP -rqF -- "$s" "$tmp"; then echo "publish: the secret in ${f#"$HERE"/} appears in a tracked file"; bad=1; fi
done < <(find state -maxdepth 3 -type f \( -name 'claude-token' -o -name 'ntfy-topic' -o -name '.env' \) -print0 2>/dev/null)
if $GREP -rlE '^-----BEGIN [A-Z ]*PRIVATE KEY-----$' "$tmp" | $GREP -q .; then
  echo "publish: a private key is in a tracked file"; bad=1
fi
(( bad == 0 )) || { echo "publish: nothing published"; exit 1; }
echo "publish: scan clean ($(git ls-files | wc -l) files)"
[[ ${1:-} == --check ]] && exit 0

# 2. one snapshot commit on the branch "public" (the working tree and main are not touched)
tree=$(git rev-parse 'HEAD^{tree}')
parent=$(git rev-parse -q --verify refs/heads/public || true)
if [[ -n $parent && $(git rev-parse "$parent^{tree}") == "$tree" ]]; then
  echo "publish: the public branch already has this code"
else
  ver=$(git describe --tags --abbrev=0 2>/dev/null || git rev-parse --short HEAD)
  c=$(git commit-tree "$tree" ${parent:+-p "$parent"} -m "pr-autopilot $ver")
  git update-ref refs/heads/public "$c"
  echo "publish: snapshot $(git rev-parse --short "$c") (pr-autopilot $ver)"
fi

# 3. push that branch only: no tags, no other branch
git push --no-tags "$REMOTE" refs/heads/public:refs/heads/main
echo "publish: done -> $(git remote get-url "$REMOTE")"
