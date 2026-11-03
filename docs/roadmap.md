# roadmap

Work through this queue in order. These are future tasks, not authorization to publish, purchase a domain, enroll in paid services, or distribute a release.

## 1. finish native acceptance

- [x] Automated and synthetic workflow coverage is in place for final-edit persistence, detached notes, independent window levels, board reopening, appearance, theme import/export, and section restoration.
- [ ] Check real Spaces, full-screen apps, physical displays, keyboard navigation, and accessibility. Test macOS 14 and Intel runtime behavior when hardware is available; keep unavailable checks explicit.
- [x] Record current test, build, packaging, and synthetic workflow evidence in `verification.md`.
- [ ] Finish hands-on acceptance and resolve any data-loss or window-lifecycle problems before release automation.

## 2. plan profiles and organization views

- [ ] Design Work/Personal profiles and repository-owner grouping/sorting using the [profile proposal](profiles.md).
- [ ] Cover multiple profiles on one Mac, enforce one writer per profile, and keep another Mac independent by default.
- [ ] Resolve safe per-profile GitHub account context before claiming simultaneous work/personal account support. Do not switch the user's global CLI account or copy credentials.
- [ ] Review safe setup transfer separately from private note/cache migration or any future sync. Keep this increment local and optional.

## 3. prepare for public development

- [ ] Choose the project license and retain dependency notices before making the repository public.
- [ ] Review tracked files and history for private data, credentials, machine paths, fixtures, screenshots, and dependency provenance. Keep demos synthetic.
- [ ] Add concise contribution and security-reporting guidance, supported-platform expectations, and a small release checklist. Keep routine maintenance practical for one maintainer and eventual outside contributors.

## 4. establish versioned releases

- [ ] Choose one lightweight release tool or pinned action that proposes semantic versions and a changelog from conventional commits. Default to a release PR against `main`, reviewed by a maintainer; avoid direct automated releases from every commit.
- [ ] Keep the app version, build number, tag, changelog, and release notes consistent. Define `feat`, `fix`, and breaking-change behavior, including expectations while the app remains pre-1.0.
- [ ] Run release packaging only for an approved release PR or an approved version tag. Verify the tag refers to the intended commit on `main`. Give release jobs only the permissions they need, at job scope.
- [ ] Publish the universal `.app` in a ZIP with a checksum and short installation notes. Keep build evidence tied to that exact version. Retain the current local ad-hoc package path for development.

## 5. make installation deliberate

- [ ] Add a DMG with a drag-to-Applications layout if it makes installation clearer. Keep the ZIP available. Use a PKG installer only if a concrete requirement needs installer behavior or privileged setup.
- [ ] Decide whether public distribution warrants Developer ID signing and notarization. Confirm enrollment requirements and actual cost before committing to paid distribution.
- [ ] Protect signing credentials and notarization access in a maintainer-approved release environment. Import them only in trusted release jobs, remove temporary keychains, verify signatures, submit for notarization, and staple and validate the resulting distributable.
- [ ] Exercise download, installation, launch, upgrade, and rollback on a separate Mac or clean test account. Describe the observed Gatekeeper behavior accurately.

## 6. add a small public home

- [ ] Check the app name for conflicts and current domain availability and renewal prices before registration. Candidate research is recorded in the private local handoff, dated 2026-11-03. Prefer an existing domain or a free static-hosting address until a new domain has an approved budget.
- [ ] Prepare the one-page mockup during public-release preparation, then build a small static page with synthetic screenshots, requirements, download links, documentation, and the source link. Default to no backend, account system, analytics, or paid build service.
- [ ] Point downloads at versioned repository releases instead of duplicating large binaries on the site. Publish and purchase only after explicit approval.

## resource defaults

- [x] Keep user data and GitHub access local. Use the user's existing `gh` login; provide no Stow server, hosted token store, or credential proxy. Never extract a token.
- [x] Disable unnecessary work: no GitHub polling when integration is off, no disabled-provider execution, and no new hosted scheduler or always-on service.
- [x] Restrict macOS CI to relevant code, project, dependency, and workflow changes; skip docs-only runs where safe. Cancel superseded runs and avoid duplicate builds. Keep cheap secret scanning separate.
- [x] Keep fork PR checks free of signing secrets and release credentials. Never run release or publishing jobs for fork PRs or untrusted PR code, including through `pull_request_target`.
- [x] Do not upload large app packages or raw logs on PRs. Store distributables for approved releases, use short retention for necessary temporary artifacts, and avoid caching private state.
- [ ] Review actual CI minutes, artifact storage, hosting, domain renewals, and developer-program costs before enabling recurring spend. Current account allowances and billing have not been established. Set explicit limits before adding paid services.

## later ideas

- [ ] Improve the bundled optional-module experience and document source-based provider reuse before designing installable plugins.
- [ ] Define installable-module packaging, discovery, API compatibility, signing, updates, permissions, and failure isolation before accepting third-party binaries. Keep trusted in-process code clearly identified.
- [ ] Consider a weather accessory or other small providers only after the host contract and installation story are settled. Keep each optional, quiet when disabled, and independent of notes and GitHub.
- [ ] Revisit menu bar UI, widgets, notifications, and GitHub write actions after the core workflow is stable and a concrete need justifies them.
- [ ] Evaluate automatic updates separately from release packaging, including trust, rollback, and ongoing hosting cost.
