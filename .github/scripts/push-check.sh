#!/usr/bin/env bash
# Fork push guard. Usage: push-check.sh <base> <tip> <remote_ref>
# Fails closed on commit identity, upstream refs in fork-authored text, and
# unaudited changes to this script. Needs git, python3 and an authenticated gh.
set -euo pipefail

HERMES='231067875+MrToAster13@users.noreply.github.com'
HERMES_NAME='Hermes T3 agent'
SELF='.github/scripts/push-check.sh'
REF_RE='(^|[^A-Za-z0-9])#[0-9]+([^A-Za-z0-9_]|$)|GeyserMC/[A-Za-z0-9._-]+#|github\.com/GeyserMC/[^ ]*/(issues|pull|discussions|commit)/|(^|[^A-Za-z0-9])GH-[0-9]+'
LINK_RE='<a [^>]*class="[^"]*issue-link|href="[^"]*github\.com/GeyserMC/[^"]*/(issues|pull|discussions|commit)/'

fail() { echo "push-check: BLOCKED: $*" >&2; exit 1; }

[ $# -eq 3 ] || fail "usage: push-check.sh <base> <tip> <remote_ref>"
base=$(git rev-parse --verify "$1^{commit}") || fail "bad base $1"
tip=$(git rev-parse --verify "$2^{commit}") || fail "bad tip $2"
remote_ref=$3
# Tags carry their own message and tagger, which this script does not check.
case $remote_ref in refs/heads/*) ;; *) fail "only branch pushes: $remote_ref" ;; esac

# Full HTML and percent decoding, repeated until the text stops changing.
decode() {
  python3 -I -c '
import html, sys, urllib.parse
t = sys.stdin.read()
while True:
    n = urllib.parse.unquote(html.unescape(t))
    if n == t:
        break
    t = n
sys.stdout.write(t)
'
}

# grep -q wrapper: 0 match, 1 no match, anything else fails closed.
matches() {
  local rc=0
  printf '%s\n' "$2" | grep -iqE "$1" || rc=$?
  [ "$rc" -le 1 ] || fail "grep error $rc"
  return "$rc"
}

# Layer 1 greps the decoded text. Layer 2 asks GitHub's renderer.
# Commit messages lose backticks and leading whitespace before the render,
# because the commit view does not treat them as markdown.
check_text() {
  local label=$1 kind=$2 text decoded html
  text=$(cat)
  decoded=$(printf '%s' "$text" | decode) || fail "$label: decode failed"
  if matches "$REF_RE" "$decoded"; then fail "$label: upstream ref"; fi
  if [ "$kind" = commit ]; then
    text=$(printf '%s\n' "$text" | sed 's/`//g; s/^[[:space:]]*//')
  fi
  [ -n "$text" ] || return 0
  html=$(gh api -X POST markdown -f mode=gfm -f context=MrToAster13/Geyser -f text="$text") \
    || fail "$label: render failed"
  if matches "$LINK_RE" "$html"; then fail "$label: renders an upstream link"; fi
}

# Author and committer of every commit in range.
log=$(git log --format='%H%x09%ae%x09%ce%x09%an%x09%cn' "$base..$tip") || fail "git log failed"
while IFS=$'\t' read -r sha ae ce an cn; do
  [ -n "$sha" ] || continue
  [ "$ae" = "$HERMES" ] && [ "$ce" = "$HERMES" ] || fail "$sha identity $ae / $ce"
  [ "$an" = "$HERMES_NAME" ] && [ "$cn" = "$HERMES_NAME" ] || fail "$sha name $an / $cn"
done <<< "$log"

printf '%s' "${remote_ref#refs/heads/}" | check_text "branch $remote_ref" branch

shas=$(git rev-list "$base..$tip") || fail "git rev-list failed"
for sha in $shas; do
  git log -1 --format=%B "$sha" | check_text "commit $sha" commit
done

# Lines the fork adds to markdown files, such as the README and notes.
# A '>' marker keeps an added line that starts with "++ " apart from file headers.
added=$(git diff --no-color -U0 --output-indicator-new='>' "$base...$tip" \
  -- ':(icase)*.md' ':(icase)*.markdown' \
  | awk '/^>/{print substr($0, 2)}') || fail "git diff failed"
printf '%s' "$added" | check_text "markdown added lines" markdown

# Changes to this script pass only when PUSH_CHECK_AUDITED equals the tip sha.
# The caller sets PUSH_CHECK_SELF_BLOB to the blob of the copy it runs
# (release, or the gate commit before release exists); the tip must match it.
expected=${PUSH_CHECK_SELF_BLOB:-}
[ -n "$expected" ] || fail "PUSH_CHECK_SELF_BLOB is not set"
new=$(git rev-parse -q --verify "$tip:$SELF") || new=none
if [ "$new" != "$expected" ] && [ "${PUSH_CHECK_AUDITED:-}" != "$tip" ]; then
  fail "$tip changes $SELF without a recorded audit"
fi

echo "push-check: ok $base..$tip -> $remote_ref"
