#!/usr/bin/env bash
# sync.sh — mirror every public non-fork GitHub repo of $GITHUB_USER
# into the corresponding project under $GITLAB_USER on gitlab.com.
#
# Idempotent: creates GitLab projects that don't exist yet, then pushes
# refs/heads/* and refs/tags/* via a fresh bare clone. Safe to run
# repeatedly (that's the whole point — this is the sync loop).
#
# Env vars (required):
#   GITHUB_USER      GitHub username to enumerate
#   GITLAB_USER      GitLab username (namespace) to mirror into
#   GITLAB_TOKEN     GitLab personal access token, scopes: api, write_repository
#
# Env vars (optional):
#   GH_TOKEN         GitHub token for `gh` — only needed for private repos
#                    or to raise the anonymous rate limit
#   INCLUDE_FORKS    "1" to include forks (default: skip)
#   DRY_RUN          "1" to list what would happen without touching anything
#   ONLY             space- or newline-separated list of repo names to sync
#                    (default: all public non-fork repos)
#   WORKDIR          scratch dir for bare clones (default: mktemp)

set -euo pipefail

: "${GITHUB_USER:?GITHUB_USER is required}"
: "${GITLAB_USER:?GITLAB_USER is required}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"

INCLUDE_FORKS="${INCLUDE_FORKS:-0}"
DRY_RUN="${DRY_RUN:-0}"
WORKDIR="${WORKDIR:-$(mktemp -d -t gh-gl-mirror-XXXX)}"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '\033[33m[%s] WARN\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
err()  { printf '\033[31m[%s] ERR\033[0m %s\n'  "$(date -u +%H:%M:%S)" "$*" >&2; }

# ---- enumerate GitHub repos --------------------------------------------------

list_github_repos() {
  # Prefer `gh` (handles pagination + auth); fall back to raw API.
  if command -v gh >/dev/null 2>&1; then
    local filter='.[] | select(.isArchived | not)'
    [[ "$INCLUDE_FORKS" != "1" ]] && filter+=' | select(.isFork | not)'
    gh repo list "$GITHUB_USER" --visibility public --limit 1000 \
      --json name,isFork,isArchived,defaultBranchRef \
      | jq -r "$filter"' | .name'
    return
  fi
  local page=1
  while :; do
    local body
    body=$(curl -sS -H 'Accept: application/vnd.github+json' \
      ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
      "https://api.github.com/users/$GITHUB_USER/repos?type=owner&per_page=100&page=$page")
    local count
    count=$(jq 'length' <<<"$body")
    [[ "$count" == "0" ]] && break
    local filter='.[] | select(.private|not) | select(.archived|not)'
    [[ "$INCLUDE_FORKS" != "1" ]] && filter+=' | select(.fork|not)'
    jq -r "$filter"' | .name' <<<"$body"
    (( page++ ))
  done
}

# ---- GitLab helpers ----------------------------------------------------------

# Sanitize a GitHub repo name into a valid GitLab path.
# GitLab rules (from the API's own error message): may contain only
# [a-zA-Z0-9_.-]; must not start with '-', '_', or '.'; must not end
# with '-', '_', '.', '.git', or '.atom'. GitLab also rejects runs of
# consecutive dashes in the derived path even though the error text
# doesn't mention it (observed: "intune---kali-linux-guide" fails).
gl_path() {
  local n="$1"
  n=$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-')
  n=$(printf '%s' "$n" | sed -E 's/-+/-/g')                # collapse ---
  n=$(printf '%s' "$n" | sed -E 's/\.(git|atom)$//')        # trailing suffixes
  n=$(printf '%s' "$n" | sed -E 's/^[._-]+//; s/[._-]+$//') # strip ends
  printf '%s' "$n"
}

gl_api() {
  local method="$1" path="$2"
  shift 2
  curl -sS -X "$method" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H 'Content-Type: application/json' \
    "$@" "https://gitlab.com/api/v4$path"
}

gl_project_exists() {
  local ns_path="$1"                             # e.g. suicidalteddy/reponame
  local encoded
  encoded=$(jq -rn --arg s "$ns_path" '$s|@uri')
  # Follow redirects (-L): GitLab returns 301 when the namespace has been
  # renamed but the project still exists (username 'suicidalteddy' redirects
  # to the canonical namespace path 'harmlessteddy', for example). Without
  # -L we'd see 301 and wrongly conclude the project is missing, then try
  # to create it and get "has already been taken".
  local status
  status=$(curl -sSL -o /dev/null -w '%{http_code}' \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "https://gitlab.com/api/v4/projects/$encoded")
  [[ "$status" == "200" ]]
}

gl_create_project() {
  local name="$1" path="$2"
  # Display name has its own rules: must start with letter/digit/emoji/'_'.
  # Strip leading non-alphanumerics so names like "-foo-" become "foo-".
  local display
  display=$(printf '%s' "$name" | sed -E 's/^[^A-Za-z0-9_]+//')
  [[ -z "$display" ]] && display="$path"
  gl_api POST /projects \
    --data "$(jq -n --arg name "$display" --arg path "$path" --arg desc "Mirror of https://github.com/$GITHUB_USER/$name" '{
      name: $name, path: $path,
      visibility: "public",
      initialize_with_readme: false,
      description: $desc
    }')"
}

# ---- per-repo sync -----------------------------------------------------------

sync_one() {
  local name="$1"
  local gl
  gl=$(gl_path "$name")
  local ns_path="$GITLAB_USER/$gl"
  local gh_url="https://github.com/$GITHUB_USER/$name.git"
  local gl_url="https://oauth2:${GITLAB_TOKEN}@gitlab.com/${ns_path}.git"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY $name  ->  gitlab.com/$ns_path"
    return
  fi

  if ! gl_project_exists "$ns_path"; then
    log "create $ns_path"
    local resp
    resp=$(gl_create_project "$name" "$gl")
    if ! jq -e '.id' >/dev/null <<<"$resp"; then
      err  "$name: GitLab create failed: $(jq -c '{message,error}' <<<"$resp")"
      return 1
    fi
  fi

  local bare="$WORKDIR/$name.git"
  rm -rf "$bare"
  log "clone $name"
  if ! git clone --quiet --mirror "$gh_url" "$bare" 2>&1 | sed 's/^/    /'; then
    err "$name: clone failed"; return 1
  fi

  # Push refs/heads + refs/tags only. Skip refs/pull/* (GitLab rejects them).
  # Deliberately NON-force: since this script is the only writer, non-force
  # will always succeed for a proper mirror. If it fails with "fetch first",
  # GitLab has diverged from GitHub — surface that as a warning and skip,
  # rather than silently overwriting content the user might want to keep.
  log "push  $name -> $ns_path"
  local push_out
  push_out=$(git -C "$bare" push --prune "$gl_url" \
        'refs/heads/*:refs/heads/*' \
        'refs/tags/*:refs/tags/*' 2>&1)
  local push_rc=$?
  printf '%s\n' "$push_out" | sed 's/^/    /'
  if (( push_rc != 0 )); then
    if grep -qE '\(fetch first\)|non-fast-forward' <<<"$push_out"; then
      warn "$name: GitLab has diverged from GitHub — skipping (resolve manually or force-push)"
      rm -rf "$bare"
      return 0   # Not a failure; a mirror can't overwrite blind
    fi
    err "$name: push failed"
    return 1
  fi
  rm -rf "$bare"
}

# ---- main --------------------------------------------------------------------

main() {
  log "workdir: $WORKDIR"
  local -a repos=()
  if [[ -n "${ONLY:-}" ]]; then
    read -r -a repos <<<"$ONLY"
  else
    mapfile -t repos < <(list_github_repos)
  fi
  log "syncing ${#repos[@]} repo(s)  forks=$INCLUDE_FORKS  dry=$DRY_RUN"

  local ok=0 fail=0
  local -a failed=()
  for r in "${repos[@]}"; do
    # Use $((x+1)) not ((x++)) — the latter returns the pre-value, and an
    # arithmetic expression evaluating to 0 exits nonzero under `set -e`,
    # which would kill the loop after the very first success.
    if sync_one "$r"; then ok=$((ok+1)); else fail=$((fail+1)); failed+=("$r"); fi
  done

  log "done  ok=$ok  fail=$fail"
  if (( fail > 0 )); then
    err "failed: ${failed[*]}"
    exit 1
  fi
}

main "$@"
