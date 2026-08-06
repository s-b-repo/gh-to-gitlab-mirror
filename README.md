# gh-to-gitlab-mirror

One-way mirror of every public non-fork repo on `github.com/s-b-repo`
into `gitlab.com/suicidalteddy`. Runs every 15 minutes on a scheduled
GitHub Actions workflow, plus on-demand via `workflow_dispatch`.

## What it does

1. Enumerates public non-fork repos under `$GITHUB_USER` (via `gh` or the
   REST API).
2. For each repo, creates the corresponding project under
   `gitlab.com/$GITLAB_USER/<name>` if it doesn't exist yet.
3. Bare-clones from GitHub and pushes `refs/heads/*` + `refs/tags/*` to
   GitLab with `--prune`. GitHub-only refs (`refs/pull/*`) are excluded
   because GitLab rejects them.

The push is force-with-prune. **GitLab is a read-only replica** —
anything committed directly to a GitLab mirror will be overwritten on
the next sync. That's the point.

## First-time setup

1. **Create a GitLab PAT** at
   <https://gitlab.com/-/user_settings/personal_access_tokens> with
   scopes `api` and `write_repository`.

2. **Bootstrap locally** (creates all GitLab projects + first push;
   quicker than waiting for the first cron tick):

   ```bash
   export GITHUB_USER=s-b-repo
   export GITLAB_USER=suicidalteddy
   export GITLAB_TOKEN=glpat-xxxxxxxx        # from step 1
   # export GH_TOKEN=$(gh auth token)         # optional, avoids rate limits
   # export DRY_RUN=1                         # to preview first
   ./sync.sh
   ```

3. **Create a GitHub repo** for this mirror hub and push it:

   ```bash
   gh repo create gh-to-gitlab-mirror --public --source=. --remote=origin --push
   ```

4. **Add the GitLab token as a secret** on that repo:

   ```bash
   gh secret set GITLAB_TOKEN --body "$GITLAB_TOKEN"
   ```

   (Optional overrides — only set if you don't want the workflow
   defaults `s-b-repo` / `suicidalteddy`:)

   ```bash
   gh variable set GH_USER --body "s-b-repo"
   gh variable set GL_USER --body "suicidalteddy"
   ```

5. **Kick off the first Actions run** to confirm it works end-to-end:

   ```bash
   gh workflow run "Mirror GitHub → GitLab"
   gh run watch
   ```

After that: cron takes over.

## Ad-hoc operations

Sync one repo right now, from Actions:

```bash
gh workflow run "Mirror GitHub → GitLab" -f only=peregrine
```

Dry-run everything (list only, no writes):

```bash
gh workflow run "Mirror GitHub → GitLab" -f dry_run=true
```

Same from your laptop:

```bash
DRY_RUN=1 ONLY="peregrine s-b-repo.github.io" ./sync.sh
```

## Known limits

- **Git LFS** objects are not fetched. If any repo uses LFS, add
  `git lfs fetch --all` + `git lfs push --all` around the push step.
- **Releases, issues, PRs, wikis** don't cross over — this is a git-refs
  mirror only. If you need release binaries, use a tool like
  [`nixpkgs/repo-mirror`](https://github.com/) or the GitLab releases
  API in a follow-up job.
- **New repos on GitHub** are picked up automatically on the next cron
  run — no per-repo setup needed.
- **Renamed / deleted GitHub repos**: the old GitLab project is left
  alone (the enumerator just stops seeing it). Delete it manually if
  you want it gone.
- **Rate limits**: GitLab allows ~2000 API req/min for authenticated
  users; 218 repos × a few calls each is comfortably under that.
- **Runtime**: a full sync of 218 repos is dominated by `git clone`
  bandwidth. Expect anywhere from 5 min (small repos) to 40+ min
  (large history). The workflow has a 60 min timeout and a concurrency
  guard so runs never stack.
