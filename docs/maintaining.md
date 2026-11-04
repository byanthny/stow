# Maintaining

Notes for the repository owner. Each command below changes a GitHub setting; review it before running it.

## Repository settings

These keep outside contributions safe once the repository is public: private vulnerability reports for [SECURITY.md](../SECURITY.md), Dependabot alerts, GitHub-owned actions only, a read-only workflow token, approval before any outside contributor's workflow runs on macOS runners, and deleting a pull request's branch once it merges. Dependabot security updates stay off; `.github/dependabot.yml` proposes action updates in one pull request a month instead.

```sh
repo=byanthny/stow
gh api -X PUT "repos/$repo/private-vulnerability-reporting"
gh api -X PUT "repos/$repo/vulnerability-alerts"
gh api -X PUT "repos/$repo/actions/permissions" -F enabled=true -f allowed_actions=selected
gh api -X PUT "repos/$repo/actions/permissions/selected-actions" -F github_owned_allowed=true -F verified_allowed=false
gh api -X PUT "repos/$repo/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
gh api -X PUT "repos/$repo/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors
gh api -X PATCH "repos/$repo" -F delete_branch_on_merge=true
```

If the `fork-pr-contributor-approval` call is rejected, set **Settings → Actions → General → Approval for running fork pull request workflows** to require approval for all outside contributors.

Protect `main` with a ruleset: changes through pull requests with no required approvals, merge commits only, signed commits, no force-push or deletion, and the `checks` workflow's `secrets` and `build` jobs as required checks. Docs-only changes skip `build`, which still satisfies the rule. The `acceptance` workflow's jobs are named `acceptance-build` and `acceptance-smoke`, so a skipped acceptance run can't stand in for `build`. Merge commits keep each commit's own signature, and GitHub signs the merge commit.

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
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["merge"]
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

## Going public

Check the roadmap's public-development items first, then change visibility. Secret scanning and push protection are free for public repositories, so turn them on right after the switch:

```sh
gh repo edit "$repo" --visibility public --accept-visibility-change-consequences
gh api -X PATCH "repos/$repo" --input - <<'JSON'
{ "security_and_analysis": { "secret_scanning": { "status": "enabled" }, "secret_scanning_push_protection": { "status": "enabled" } } }
JSON
```

Once the site has an address, set `site` to it and make it the repository's homepage:

```sh
gh repo edit "$repo" --homepage "$site"
```

## Releases

1. On a branch cut from an up-to-date `main`, run `./scripts/release.sh`. It suggests the next version from the conventional commits since the last `v*` tag. While Stow is 0.x, a `feat` commit or a breaking change bumps the minor number, and any other commit bumps the patch. To choose another version, pass it, as in `./scripts/release.sh 0.3.0`; it must be higher than the current one. The script sets `MARKETING_VERSION` and raises `CURRENT_PROJECT_VERSION` by one in `project.yml` and the Xcode project, runs `./scripts/test.sh`, and prints the commands for the next steps. It doesn't push, tag, or publish anything.
2. Commit the change as `chore(release): X.Y.Z`, then open its pull request and merge it.
3. Push a signed `vX.Y.Z` tag on the merge commit, then publish its release, marked as a pre-release while Stow is in alpha.
4. Publishing starts the `release` workflow. It builds the unsigned DMG from the tag and attaches it with its SHA-256 and a build provenance attestation. To build an existing release again, run the workflow by hand with its tag.

Builds stay unsigned until Developer ID signing and notarization are in place; see the [roadmap](roadmap.md). Attestations need the repository to be public.

## Acceptance runs

Add the `acceptance` label to a pull request from a branch in this repository, or run the `acceptance` workflow by hand once it is on `main`, to build a universal Debug app and run its synthetic smoke checks on an Intel runner. The label doesn't start a run for a fork's pull request. Record results in [verification](verification.md).

## Accessibility audit

Before a release, and after UI changes, run `./scripts/accessibility.sh` on a Mac. It runs Xcode's accessibility audit against the Debug app with synthetic state, and CI doesn't run it. macOS may ask an administrator to approve Automation Mode, including again after the Mac sleeps, and the test moves the pointer for about half a minute. Record results in [verification](verification.md).
