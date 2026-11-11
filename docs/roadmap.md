# Roadmap

Work through this queue in order. These are future tasks, not authorization to publish, purchase a domain, enroll in paid services, or distribute a release.

## Path to v1

The [plan to v1](v1-plan.md) splits these into work packages, and the [module design](modules.md) covers the module interface. There are no dates: a release ships when its checks pass and the owner has tried it.

- [ ] **0.3.1, fixes:** faster typing in long notes, a green outline on approved cards, merged cards that leave after one refresh, and the security and correctness fixes from the 0.3.0 audits.
- [ ] **0.4.0, lean:** lower CPU, memory, and idle wakeups, measured before and after.
- [ ] **0.5.0, modules:** GitHub runs as a module on the interface any module uses, and the `gh` location is kept per Mac.
- [ ] **0.6.0, cards and notes:** notes under their card, notes that link to any web page, Copy with link, a Watching section, pull requests you reviewed, review comments on cards, and sample module cards.
- [ ] **0.7.0, sticky notes:** a quick-note shortcut, note colors, a menu bar item, launch at login, and secure notes.
- [ ] **0.8.0, install and polish:** Move to Applications, smooth animations that respect Reduce Motion, and a keyboard and VoiceOver pass.
- [ ] **1.0.0, stable:** a new saved-data format with a backup, a release candidate, about two weeks with no data loss, then the first stable release. It ships unsigned; Developer ID signing follows.

## 1. Finish native acceptance

- [x] Automated and synthetic workflow coverage is in place for final-edit persistence, detached notes, independent window levels, board reopening, appearance, theme import/export, and section restoration.
- [x] Check real Spaces, full-screen apps, and Dock/focus on macOS 26.5 (2026-11-03). Stow windows stay out of other apps' full-screen spaces by design.
- [ ] Check physical displays, keyboard navigation, and accessibility. Intel passes the acceptance smoke checks in CI on macOS 15, and 0.3.0 was tried hands-on on an Intel Mac with macOS 26.5.2 Tahoe (2026-11-05). macOS 14 is untested because no runner or machine is available; keep unavailable checks explicit.
- [x] Keep notes as live Markdown files with conflict preservation, independent Markdown import/export, and validated full backup/restore. Managed folder selection and cloud sync remain separate future work.
- [x] Record current test, build, packaging, and synthetic workflow evidence in `verification.md`.
- [ ] Finish hands-on acceptance and resolve any data-loss or window-lifecycle problems before release automation.

## 2. Plan profiles and organization views

- [x] Design profiles and repository-owner grouping and sorting: the [profile design](profiles.md) and its [implementation plan](profiles-plan.md), approved 2026-11-03.
- [x] Cover multiple profiles on one Mac, enforce one writer per profile, and keep another Mac independent by default. Implemented on the profiles branch, pending hands-on acceptance.
- [x] Group and sort pull requests by repository owner, and filter by owner per profile.
- [ ] Resolve safe per-profile GitHub account context before claiming simultaneous work/personal account support. Today every profile uses the account `gh` is signed in as, and a different account pauses the profile. Do not switch the user's global CLI account or copy credentials.
- [ ] Review safe setup transfer separately from private note/cache migration or any future sync. Keep this increment local and optional.

## 3. Prepare for public development

- [x] Choose the project license and retain dependency notices before making the repository public: GPL-3.0-or-later, chosen 2026-11-03.
- [x] Review tracked files and history for private data, credentials, machine paths, fixtures, screenshots, and dependency provenance. Keep demos synthetic. Audited 2026-11-03; no history rewrite needed.
- [x] Add concise contribution and security-reporting guidance and supported-platform expectations.
- [x] Add a small release checklist: [maintaining](maintaining.md#releases) and `scripts/release.sh` (2026-11-04).
- [x] Before making the repository public, apply the reviewed settings: private vulnerability reporting, secret scanning with push protection, Dependabot alerts, a `main` ruleset, GitHub-owned actions only, and approval for outside contributors' workflows. Applied, and confirmed on 2026-11-05 against [maintaining](maintaining.md).

## 4. Establish versioned releases

- [x] Choose one lightweight release tool: `scripts/release.sh` suggests the next version from conventional commits and prepares a release pull request against `main`. Release notes are written for each release; there is no changelog file.
- [x] Keep the app version, build number, tag, and release notes consistent. [Maintaining](maintaining.md#releases) defines how `feat`, `fix`, and breaking changes bump the version while Stow is 0.x.
- [ ] Run release packaging only for an approved version tag. The `release` workflow builds from a published release's tag. Still open: build the DMG in a job without write or attestation permissions, then attest and upload it from a second job that runs no repository code.
- [x] Publish a universal build with a checksum and short installation notes: the DMG in section 5. `./scripts/package.sh` still makes a local ZIP for development.

## 5. Make installation deliberate

- [x] Ship an unsigned alpha DMG with a drag-to-Applications layout, built by GitHub Actions from each release tag with its SHA-256 and a build provenance attestation (owner's call, 2026-11-04). Keep the ZIP for local packages. Use a PKG installer only if a concrete requirement needs installer behavior or privileged setup.
- [ ] Replace the unsigned DMG with Developer ID signed and notarized builds, after v1. Confirm enrollment requirements and actual cost first.
- [ ] Protect signing credentials and notarization access in a maintainer-approved release environment. Import them only in trusted release jobs, remove temporary keychains, verify signatures, submit for notarization, and staple and validate the resulting distributable.
- [ ] Exercise download, installation, launch, upgrade, and rollback on a separate Mac or clean test account. Describe the observed Gatekeeper behavior accurately.

## 6. Add a small public home

- [x] Check the app name and the domain. Stow keeps its name and lives at stow.byanthny.com, so no new domain was registered (2026-11-04).
- [x] Build a small static page with synthetic screenshots, requirements, download links, documentation, and the source link: https://stow.byanthny.com, live since 2026-11-04, with no backend, analytics, or third-party requests.
- [x] Point downloads at versioned repository releases instead of duplicating large binaries on the site.

## Resource defaults

- [x] Keep user data and GitHub access local. Use the user's existing `gh` login; provide no Stow server, hosted token store, or credential proxy. Never extract a token.
- [x] Disable unnecessary work: no GitHub polling when integration is off, no disabled-provider execution, and no new hosted scheduler or always-on service.
- [x] Restrict macOS CI to relevant code, project, dependency, and workflow changes; skip docs-only runs where safe. Cancel superseded runs and avoid duplicate builds. Keep cheap secret scanning separate.
- [x] Keep fork PR checks free of signing secrets and release credentials. Never run release or publishing jobs for fork PRs or untrusted PR code, including through `pull_request_target`.
- [x] Do not upload large app packages or raw logs on PRs. Store distributables for approved releases, use short retention for necessary temporary artifacts, and avoid caching private state.
- [ ] Review actual CI minutes, artifact storage, hosting, domain renewals, and developer-program costs before enabling recurring spend. Current account allowances and billing have not been established. Set explicit limits before adding paid services.

## After profiles, in order

Ideas taken from Zed, Ghostty, and Zen, queued until after v1. Each is opt-in or a setting with a default. The quick-note shortcut from this list is planned for 0.7.0.

- [ ] Light and dark themes that follow macOS, with a live theme preview. For example, `preset = dark:graphite,light:paper` in the config, as Ghostty does. Arrowing through themes previews them, and Escape restores the previous one, as in Zed.
- [ ] Compact mode that hides the board header until the pointer reaches it, as in Zen.
- [ ] A command palette listing every action, as in Zed.
- [ ] One text config for all settings with the defaults shown, as in Ghostty and Zed. It never contains notes, pull requests, account data, or machine paths, so it stays safe to share.

## Later ideas

- [ ] Improve the bundled optional-module experience and document source-based provider reuse before designing installable plugins.
- [ ] Define installable-module packaging, discovery, API compatibility, signing, updates, permissions, and failure isolation before accepting third-party binaries. Keep trusted in-process code clearly identified. Prefer a sandbox that grants each extension only declared capabilities, like Zed's WebAssembly extensions, over loading outside code into the app.
- [ ] Consider a weather accessory or other small providers only after the host contract and installation story are settled. Keep each optional, quiet when disabled, and independent of notes and GitHub.
- [ ] Revisit widgets, notifications, and GitHub write actions after the core workflow is stable and a concrete need justifies them. The menu bar item is planned for 0.7.0.
- [ ] A status module: uptime for your own sites and status pages such as GitHub's, with notifications. Opt-in, like every module.
- [ ] An iPhone and iPad app with widgets, to read notes and watch modules away from the Mac. It needs sync across devices designed first.
- [ ] Evaluate automatic updates separately from release packaging, including trust, rollback, and ongoing hosting cost. 0.3.0 adds an opt-in update check that only links to the release page.
