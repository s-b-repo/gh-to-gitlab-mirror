#!/usr/bin/env bash
# scrub.sh — remove a specific secret string from a GitHub repo's full
# history, force-push, and re-mirror to GitLab.
#
# Usage:
#   scrub.sh <github-repo-url> <secret-string> [<secret-string>...]
#
# Requires: git-filter-repo (in $PATH), gh (auth'd for the repo), and
# ~/.mirror-tokens with GITLAB_TOKEN for the follow-up mirror push.
#
# History rewrite is DESTRUCTIVE and force-pushes to origin. Callers
# should already have user confirmation.

set -euo pipefail

usage() { echo "usage: $0 <repo-url> <secret> [<secret>...]" >&2; exit 2; }
(( $# >= 2 )) || usage

REPO_URL="$1"; shift
SECRETS=("$@")

: "${GITLAB_TOKEN:=$(grep -E '^GITLAB_TOKEN=' "$HOME/.mirror-tokens" | cut -d= -f2-)}"
: "${GITLAB_USER:=harmlessteddy}"  # canonical namespace path (see README)

command -v git-filter-repo >/dev/null || { echo "git-filter-repo not in PATH" >&2; exit 3; }

WORK=$(mktemp -d -t scrub-XXXX)
trap 'rm -rf "$WORK"' EXIT

REPO_NAME=$(basename "$REPO_URL" .git)
echo "[$REPO_NAME] cloning bare from GitHub…"
git clone --quiet --bare "$REPO_URL" "$WORK/$REPO_NAME.git"
cd "$WORK/$REPO_NAME.git"

# Build the replace-text expression file: one literal per line.
# git-filter-repo replaces each match with ***REMOVED***.
REPLACE_FILE=$(mktemp)
for s in "${SECRETS[@]}"; do
  # literal:… tells filter-repo not to interpret regex metachars
  printf 'literal:%s==>***REMOVED***\n' "$s"
done > "$REPLACE_FILE"

echo "[$REPO_NAME] rewriting history — removing ${#SECRETS[@]} secret(s)…"
git filter-repo --force --replace-text "$REPLACE_FILE"

# Verify the rewrite actually did what we asked. If any secret is still
# reachable from HEAD we bail rather than push a silent no-op (the
# original scrub failed exactly this way — filter-repo rewrote SHAs but
# didn't substitute, and the leaked push looked successful).
for s in "${SECRETS[@]}"; do
  if git grep -qF "$s" HEAD -- 2>/dev/null; then
    echo "[$REPO_NAME] ERR: post-rewrite tree STILL contains secret; aborting push" >&2
    exit 4
  fi
done

# git-filter-repo strips the remote by design. Re-add origin.
git remote add origin "$REPO_URL"

echo "[$REPO_NAME] force-pushing rewritten history to GitHub…"
git push --force --all origin
git push --force --tags origin

# The GitLab mirror will diverge on the next sync — force-push it too now
# so we don't leave the leaked secret behind on the replica.
GL_PATH=$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' \
          | tr -c 'a-z0-9._-' '-' \
          | sed -E 's/-+/-/g; s/\.(git|atom)$//; s/^[._-]+//; s/[._-]+$//')
GL_URL="https://oauth2:${GITLAB_TOKEN}@gitlab.com/${GITLAB_USER}/${GL_PATH}.git"
echo "[$REPO_NAME] force-pushing rewritten history to GitLab ($GITLAB_USER/$GL_PATH)…"
# Force IS required here — GitLab already has the old commits from the mirror
git push --force "$GL_URL" 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' \
  || echo "[$REPO_NAME] WARN: GitLab push failed — likely branch protection; unprotect and re-run"

rm -f "$REPLACE_FILE"
echo "[$REPO_NAME] done. Rotate the secret NOW — it may already be indexed/scraped."
