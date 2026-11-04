# maintaining

Notes for the repository owner. Each command below changes a GitHub setting; review it before running it.

## repository settings

These keep outside contributions safe once the repository is public: private vulnerability reports for [SECURITY.md](../SECURITY.md), Dependabot alerts, GitHub-owned actions only, a read-only workflow token, and approval before any outside contributor's workflow runs on macOS runners.

```sh
repo=byanthny/stow
gh api -X PUT "repos/$repo/private-vulnerability-reporting"
gh api -X PUT "repos/$repo/vulnerability-alerts"
gh api -X PUT "repos/$repo/automated-security-fixes"
gh api -X PUT "repos/$repo/actions/permissions" -F enabled=true -f allowed_actions=selected
gh api -X PUT "repos/$repo/actions/permissions/selected-actions" -F github_owned_allowed=true -F verified_allowed=false
gh api -X PUT "repos/$repo/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
gh api -X PUT "repos/$repo/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors
```

If the last call is rejected, set **Settings → Actions → General → Approval for running fork pull request workflows** to require approval for all outside contributors.

Protect `main` with a ruleset: no deletion or force-push, signed commits, changes through pull requests, and the `checks` workflow's `secrets` and `build` jobs. Docs-only changes skip `build`, which still satisfies the rule. Use squash or merge commits; GitHub cannot sign rebase merges.

```sh
gh api -X POST "repos/$repo/rulesets" --input - <<'JSON'
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [{ "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request" }],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_signatures" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [{ "context": "secrets" }, { "context": "build" }]
      }
    }
  ]
}
JSON
```

## going public

Check the roadmap's public-development items first, then change visibility. Secret scanning and push protection are free for public repositories, so turn them on right after:

```sh
gh repo edit "$repo" --visibility public --accept-visibility-change-consequences
gh api -X PATCH "repos/$repo" --input - <<'JSON'
{ "security_and_analysis": { "secret_scanning": { "status": "enabled" }, "secret_scanning_push_protection": { "status": "enabled" } } }
JSON
```

Publish no binaries until Developer ID signing and notarization are in place; see the [roadmap](roadmap.md).

## acceptance runs

Add the `acceptance` label to a pull request, or run the `acceptance` workflow by hand once it is on `main`, to build a universal Debug app and run its synthetic smoke checks on an Intel runner. The same run audits accessibility on an Apple silicon runner with `scripts/accessibility.sh`; add the label to pull requests that change the UI. Record results in [verification](verification.md).
