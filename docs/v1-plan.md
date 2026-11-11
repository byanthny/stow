# Plan to v1

Written 2026-11-10 against `main` at f28e735, which is 0.3.0 plus the site update. The [module design](modules.md) covers the module interface, the host, and note links.

## Context

0.3.0 shipped on 2026-11-05. Hands-on testing on Apple silicon and an Intel Mac with macOS 26.5.2 raised these needs: less resource use, clearer cards, notes under cards, notes that link to anything, module cards, a Watching section, secure notes, and the leftovers from the 0.3.0 audits. This plan carries them through v1 as work packages that agents can pick up.

**Direction:**
- Stow is a notes app first, with optional modules. With every module off it should be a modern Stickies replacement.
- First launch still asks about GitHub; the main audience is developers.
- GitHub becomes a full module before v1. Modules are compiled in for v1.
- The core stays free of opinions, so features can be built as modules.

**Decisions:**
- v1 ships unsigned. Developer ID signing comes after v1.
- Updates stay a notice only.
- Small releases, each tested hands-on before the next.
- The installer keeps macOS's quarantine flag.
- v1 includes a quick-note shortcut, note colors, a menu bar item, launch at login, and secure notes.

## Release order

No dates. A release ships when its gate passes and the owner has tried it.

| Release | Theme | What the owner gets |
| --- | --- | --- |
| 0.3.1 | Fixes | Faster typing in long notes (PR 21); approved cards outlined in green; merged cards leave after one refresh; security and correctness fixes |
| 0.4.0 | Lean | Lower CPU, memory and idle wakeups, with before-and-after numbers; no visible feature changes |
| 0.5.0 | Modules | GitHub runs as a module; the `gh` location is kept per Mac; nothing looks different |
| 0.6.0 | Cards and notes | Notes under their card; notes that link to any web page; Copy with link; a Watching section; pull requests you reviewed; review comments on cards; sample module cards |
| 0.7.0 | Sticky notes | Quick-note shortcut; note colors; menu bar item; launch at login; secure notes |
| 0.8.0 | Install and polish | Move to Applications; smooth animations; keyboard and VoiceOver pass |
| 1.0.0 | Stable | New saved-data format with a backup; release candidate; about two weeks with no data loss; stable release |

## Progress

Tick a package when its change is merged.

**0.3.1**
- [ ] R1. Land PR 21
- [ ] R2. Harden launching `gh`
- [ ] R3. Lock failures refuse instead of unlocking
- [ ] R4. Update check errors and retries
- [ ] R5. Split the release workflow
- [ ] R6. Editor hit tests
- [ ] R7. Approved outline and merged cards
- [ ] R8. Release 0.3.1

**0.4.0**
- [ ] L1. Measure a baseline
- [ ] L2. Split AppStore into files
- [ ] L3. Enums for reasons and states
- [ ] L4. Shared file and color helpers
- [ ] L5. Pure logic into StowCore
- [ ] L6. One alert helper and one menu bridge
- [ ] L7. Tasks that stop with their owner
- [ ] L8. One model per note
- [ ] L9. Remaining costs
- [ ] L10. Measure again and release 0.4.0

**0.5.0**
- [ ] M0. Note link model, StowCore only
- [ ] M1. SDK v2 values and a card adapter
- [ ] M2. Module host
- [ ] M3. GitHubModule and the binding
- [ ] M4. Run the board on modules
- [ ] M5. Remove the GitHub-specific host code

**0.6.0**
- [ ] C1. Sample module cards
- [ ] C2. Notes under cards and web links
- [ ] C3. Watching section
- [ ] C4. Pull requests you reviewed
- [ ] C5. Review activity on cards

**0.7.0**
- [ ] S1. Quick-note shortcut
- [ ] S2. Note colors
- [ ] S3. Menu bar item
- [ ] S4. Launch at login
- [ ] S5. Secure notes

**0.8.0**
- [ ] I1. Move to Applications
- [ ] I2. Smoothness
- [ ] I3. Accessibility pass

**1.0.0**
- [ ] V1. Schema 2
- [ ] V2. Release candidate
- [ ] V3. Docs and site
- [ ] V4. 1.0.0

## Execution

**Roles and models**
| Role | Model | Does |
| --- | --- | --- |
| Lead session, one per release | Opus | Reads this plan, hands out work packages, reviews every diff, runs the full suite, pushes, opens PRs, reports to the owner |
| Builder subagent, one per work package | Opus | Works in its own worktree and branch: code, tests, the fails-without-the-fix check, signed commits |
| Mechanical subagent | Sonnet | File moves (L2, L5), docs (P0), the site's version line |
| Reviewer subagent | Opus | Reads the diff without the builder's explanation; a security review as well for R2, R3, S5 and I1 |
| Design pass | Fable | Before any code for M1–M4 (the GitHub module move) and V1 (schema 2) |
| Search | Explore agents | Read-only lookups |

**Per work package:** build → package tests → fails-without-fix check → review → full suite → branch done locally → PR when one of the two slots is free → CI → the owner merges.

**Per release:** all packages merged → `release.sh` and the version PR with the `acceptance` label → a build for the owner → the owner's hands-on list → notes → signed tag → publish → site version line.

**Limits**
- At most three builders at once, and only where the release's parallel list says files don't overlap.
- One full test run at a time; parallel hosted runs are flaky.
- The lead is the only one that pushes or opens PRs.

**What needs the owner**
- Merging each PR, and the go-ahead for each release.
- The signing agent unlocked, and the signed tag.
- Approving Automation Mode for the accessibility audit.
- The hands-on list for each release.

While the owner is away, the lead keeps building packages that need none of those and queues the rest.

**Picking up again:** a new session reads this file, its own project notes if it keeps any, `git branch --list`, and the open PRs. The lead ticks each finished package under [progress](#progress).

## How agents work

**Setup**
- Read `AGENTS.md`, [architecture](architecture.md), this plan, and the [module design](modules.md) first.
- One lead session per release. It runs work packages as subagents, each in its own git worktree on its own branch, and reviews every diff before pushing.
- Two writers never edit the same file at once. Each release lists what can run in parallel.

**Commits and PRs**
- **Agents commit without asking** (owner, 2026-11-10). The plan is the approval; a commit plan no longer waits for a yes.
- **Work stays local.** Finished branches wait on this Mac, stacked on each other in merge order.
- **At most two draft PRs are open at once,** counting PR 21. When one merges, push the next branch in order and open its PR. Dependabot's PR doesn't count.
- Signed commits only. If `git commit` fails with "failed to write commit object", the signing agent is locked: stop and report. Never commit unsigned, never `--no-verify`, never force-push.
- One concern per commit, conventional subjects such as `fix(notes): …`. No attribution lines, no people's names, US spelling.
- Comments are one line and say what, not why. Helpers go in a module's `utils/`.
- Synthetic data only. Before each push, grep the diff and the PR text for private project names.
- PRs are drafts. The body says what changed and why, how it was tested, and what a reviewer would trip on. No hard wraps, no @-mentions, no reviewers.
- Merging, tagging and publishing need the owner's OK in chat.
- The lead session keeps a short status in chat: which branches are done locally, which two PRs are open, and what's waiting on the owner.

**Checks**
- Build and test with credentials removed from the environment, using `env -u <NAME>` for each token variable. Xcode records the build environment in its build data.
- `swift test` for package changes; `./scripts/test.sh` before every PR; `./scripts/build.sh Debug` and `Release` before a release.
- A bug fix's test must fail without the fix. Check it once by reverting the fix.
- `./scripts/accessibility.sh` for UI changes. It needs the owner at the Mac to approve Automation Mode.
- Smoke test: the Debug app with `--stow-testing-state <new empty folder> --stow-demo --stow-smoke-test`; expect 14 checks, all true.
- Hosted tests hang at launch when the Mac is locked. If `xcodebuild test` prints no "Test Case" line for five minutes, stop it and report.
- Adding or moving files in `App/` means regenerating `Stow.xcodeproj` with XcodeGen from a folder named `stow`. The project file records the folder name.

**GitHub mechanics**
- CI runs only on PRs to `main`. For a stacked branch, start `ci.yml` by hand with `workflow_dispatch`.
- Stacked PRs merge through `PUT /repos/byanthny/stow/pulls/<n>/merge-async` with `merge_method=merge`, `merge_action=direct_merge` and the head `sha`. `gh pr ready` fails on them; use the `markPullRequestReadyForReview` mutation.
- After a merge, GitHub rebases the PRs above it. Their heads change and CI reruns.

**Releasing** (`docs/maintaining.md`)
1. `./scripts/release.sh X.Y.Z` on a branch from `main`, then the version PR.
2. Add the `acceptance` label to the version PR for the Intel smoke test.
3. A dated entry in `docs/verification.md`, and `docs/roadmap.md` updated.
4. After the owner's OK: merge, signed tag on `main`, publish the pre-release with notes.
5. Check the DMG's digest against its `.sha256` and its attestation, then update the site's version line in its own PR.

## Contracts every release keeps

**Saved data until v1**
- `AppState.currentVersion` stays 1.
- 0.3.x refuses a `state.json` without `schemaVersion`, `notes`, `pins`, `dismissedIDs`, `pullRequests`, `githubEnabled` and `extensionInstances`. Keep writing them in today's shapes.
- Never add an `AccessorySlot` case; 0.3.x decodes it strictly and would go into recovery.
- New keys are optional and decode leniently: a bad value drops that value, never the note or the profile.
- 0.3.x ignores unknown keys and drops them on its next save. GitHub data must survive that round trip; other new data may not, and the release notes say so.

**Invariants from `AGENTS.md`** that the module work must keep: disabled modules never run; stale or partial data never implies readiness; a different account pauses the profile and never relabels its cache; backups omit machine-local settings; new profiles never turn GitHub or accessories on; the SDK has no SwiftUI or AppKit.

## Design

The module interface, what the host owns, GitHub's saved data until v1, and note links are in the [module design](modules.md).

### Observed state

In `App/AppStore.swift`.

```swift
@MainActor @Observable final class NoteModel: Identifiable {     // one per note
    let id: UUID; let createdAt: Date
    var markdown: String; var link: NoteLink?; var isDetached: Bool; var isAlwaysOnTop: Bool; var updatedAt: Date
    @ObservationIgnored var frame: WindowFrame?
}
@MainActor @Observable final class ModuleSlice { var cards, banners, isRefreshing, lastRefreshAt, identityMismatch }  // 0.5.0
// AppStore: var base: AppState (notes empty), var notes: [NoteModel], @ObservationIgnored var boardFrame
func snapshot() -> AppState    // the one value for saves, transfers and backups; never read from a view body
```

- `persist`, `terminationSave`, `saveAndClose` and `portableSnapshot` call `snapshot()`. `mergeLiveResult` works on models by id with today's comparisons.
- BoardView reads note identities and links, never `markdown`. A card reads its own values. NoteView reads its `NoteModel`.

## Work packages

Line numbers are as of f28e735; find by symbol if they've moved.

### P0. Put the plan in the repo
- **Files:** `docs/v1-plan.md`, `docs/modules.md`, `docs/roadmap.md`.
- **Done:** the change that added this file.

### 0.3.1 Fixes

Parallel: R1→R6 (editor), R2→R3→R4 (GitHub launch, then lock, then updates; they share `SettingsView.swift`, `ProfileManager.swift`, `ProfileSession.swift`), R5 (workflow), R7 (cards).

PR order, two at a time: P0 and R1 first (PR 21 is already open), then R2–R4 as one security PR, R6, R7, R5, then the version PR.

**R1. Land PR 21** (`perf/restyle-changes`)
- **Do:** merge `origin/main` into it, run `./scripts/test.sh`, start CI, mark it ready.
- **Done when:** the full suite passes on the merged head.

**R2. Harden launching `gh`** (`fix/gh-launch`)
- **Files:** `Sources/StowGitHub/Transport.swift`, `Sources/StowGitHub/GHClient.swift`, `App/AppStore.swift` (`configureGitHub`), `App/ProfileManager.swift`, `App/ProfileSession.swift`, `App/SettingsView.swift` (`chooseGH`), `docs/architecture.md:26`.
- **Do:**
  - Set `F_SETNOSIGPIPE` on the input pipe before writing (`Transport.swift:198`); a broken pipe becomes `requestFailed`.
  - Keep the deadline running until both output pipes drain, with `group.wait(timeout:)`; on timeout throw `.timedOut` (`:201-203`).
  - `GHClient.init(executableURL:)` drops a path that fails `isUsableExecutable`. `ProcessControl.run` checks again before launching and throws `.executableNotFound`.
  - `isUsableExecutable` and `discoverExecutable` take a folder to exclude, compared after resolving links. Pass the data folder down from ProfileManager.
  - Request recent commits only on the first details page (`GHClient.swift:27`, `:348`).
  - Say "writable by its group or other users" in the three places that say "other users".
- **Tests:** a script named `gh` that exits without reading returns an error and doesn't kill the test; one that leaves a child holding its output open times out; a `gh` inside the data folder is refused; a path made unusable after setup isn't launched; the second details page asks for no commits.

**R3. Lock failures refuse instead of unlocking** (`fix/state-lock`)
- **Files:** `Sources/StowCore/StateLock.swift:34-46`; callers `App/ProfileSession.swift:49`, `App/ProfileManager.swift:483`, `App/Windows.swift:142`, `Sources/StowCore/ProfileDeletion.swift:190`; `Tests/StowCoreTests/StateLockTests.swift:61-71`.
- **Do:** only ENOTSUP and EOPNOTSUPP mean `.unavailable`. Everything else is a new `.failed` case. A profile with a failed lock stays closed with a message. A failed app lock shows an alert and quits. ProfileManager and ProfileDeletion throw `.unwritable`.
- **Tests:** a symlink or a folder at the lock path gives `.failed`; the errno mapping is tested directly.

**R4. Update check errors and retries** (`fix/update-check-errors`)
- **Files:** `Sources/StowCore/Updates.swift:281` (`record`), `App/UpdateMonitor.swift:62,104`, `App/SettingsView.swift:214,234-244`, `Tests/StowCoreTests/UpdateTests.swift:166`, `docs/privacy.md`, `docs/architecture.md`.
- **Do:** `record` sets `lastCheckAt` only on success, so the hourly loop retries a failed check. UpdateMonitor gets an observable `problem`, set and cleared in `save()`, and Settings → Updates shows it.
- **Tests:** a failed check leaves `lastCheckAt` alone; a failed save sets `problem`.

**R5. Split the release workflow** (`ci/release-jobs`)
- **Files:** `.github/workflows/release.yml`, `docs/maintaining.md`, `docs/roadmap.md` (section 4).
- **Do:** a `build` job with `contents: read` builds the DMG and checksum and uploads them as an artifact (1-day retention, fail if missing), with the DMG name as a job output. A `publish` job with the three write permissions runs no repository code: download, `sha256sum -c`, attest, `gh release upload`. Reuse the pinned action SHAs from `acceptance.yml`.
- **Done when:** the YAML passes `actionlint` if installed. The 0.3.1 release is its real test; reverting is one commit.
- **Also:** Dependabot PR 5 bumps `actions/checkout`. The owner decides whether to merge it after this lands.

**R6. Editor hit tests** (`fix/editor-hit-tests`, on top of R1)
- **Files:** `App/NativeEditor.swift` (`link(at:)` `:358,364`; `watchClicks` `:297`), `AppTests/AppearanceIntegrationTests.swift`.
- **Do:** ⌘-click and Open Link fire only when the point is inside the link's text segments, using TextKit 2 `enumerateTextSegments`. Never touch `layoutManager`. Click-away asks `window.contentView?.hitTest` whether the click landed inside the note's scroll view.
- **Tests:** a right-click 60 points right of a link that ends its line offers no Open Link; a click on a pinned section header over a tall note ends editing.

**R7. Approved outline and merged cards** (`fix/card-approval-and-merged`)
- **Files:** `Sources/StowCore/Attention.swift`, `App/PRCard.swift:73-74`, `Sources/StowCore/Reconciliation.swift:40-57`, `Tests/StowCoreTests/CoreTests.swift:412-423`, `docs/architecture.md:48`, `App/DemoContent.swift`.
- **Do:**
  - Add `isApproved` to the snapshot: open, review decision approved, and not stale. PRCard draws its border in `.stowGreen` when it's true. The word "Approved" stays.
  - Drop an unpinned merged or closed card at the first refresh after the one that showed it: when the previous snapshot already has `terminalObservedAt`.
- **Tests:** approved, stale-approved and unapproved cases; a merged card shows once and is gone after the next refresh; a pinned one stays.

**R8. Release 0.3.1**
- Fix whatever the owner's hands-on pass finds, then follow Releasing.
- **The owner tests:** typing in a long note; ⌘-click beside a link; an approved pull request; a merged one disappearing; turning the update check on while offline; choosing a `gh` in Settings.

### 0.4.0 Lean

Serial, because the cleanup touches the same App files: L1 in parallel with L2 → L3 → L4 → L5 → L6 → L7 → L8 → L9 → L10. Build each branch on the one before it, locally. Group them into fewer PRs where one review makes sense: L2 alone, L3–L7 as one cleanup PR, L8 alone, L9 alone.

**L1. Measure a baseline** (`chore/measure`)
- **Files:** `App/DemoContent.swift`, `App/Windows.swift` (a Debug-only `--stow-demo-load <cards>,<notes>`), new `scripts/measure.sh`, `docs/verification.md`.
- **Do:** build the Debug configuration with `SWIFT_OPTIMIZATION_LEVEL=-O`, so the testing flags work on optimized code. Launch with 30 cards and 20 notes, one of them 46 KB. After a minute idle, sample `top -l 6 -s 10 -pid <pid> -stats cpu,idlew,mem` and `footprint`. Add hosted `measure` tests for typing 50 characters at 4, 46 and 100 KB.
- **Done when:** the numbers are in `docs/verification.md`.

**L2. Split AppStore into files** (`refactor/appstore-files`)
- **Do:** move code, unchanged, into `AppStore+Layout.swift`, `+GitHub.swift`, `+Notes.swift`, `+Accessories.swift` and `+Persistence.swift`. Move `draftNoteID` to the top. Widen `private` only where a region needs it. Regenerate the Xcode project.
- **Done when:** the suites pass with no test changes.

**L3. Enums for reasons and states** (`refactor/attention-enums`)
- **Files:** `Sources/StowCore/Attention.swift`, `Sources/StowCore/Models.swift`, `App/PRCard.swift:191-198`, `Sources/StowGitHub/GHClient.swift:158,472,521`, `Sources/StowCore/Reconciliation.swift:26,35`, `App/AppStore+GitHub.swift`.
- **Do:** `AttentionReason: String` with today's text as raw values and `tone`, `isAboutChecks`, `isAboutReview`; `CheckOutcome` with `init(githubState:)`, `tone`, `symbol`, `isPassing`; `ReviewDecision`; `PullRequestSnapshot.markStale()` used at all seven sites. Make the three check-state lists agree: neutral and skipped are neutral, not passing.
- **Tests:** iterate `allCases`; a stale snapshot never classifies as ready.

**L4. Shared file and color helpers** (`refactor/private-file-and-colors`)
- **Files:** new `Sources/StowCore/utils/PrivateFile.swift`; `Sources/StowCore/LiveNotes.swift`; `App/DataTransferView.swift:244-317`; `App/AppearanceView.swift:148-152,216-241`; `Sources/StowCore/utils/RGBColor.swift`; `App/Theme.swift:109-117`; `App/ProfilesSettingsView.swift:429-498`.
- **Do:** `PrivateFile` with bounded read, create-new, atomic replace and private folder; LiveNoteIO keeps coordination on top. `RGBColor` goes public with a hue, saturation, brightness init. ProfilePalette and `ThemeConfigTransfer.decode` move to StowCore. AppearanceView uses the clamped hex.
- **Tests:** PrivateFile refuses links and oversize files; palette colors round-trip.

**L5. Pure logic into StowCore** (`refactor/core-logic`)
- **Do:** move SectionCards (`App/BoardView.swift:347-376`) into `BoardCards.swift`; `AddOwnerPrompt.problem` and the OwnerSelection helpers (`App/OwnerControl.swift:139-187`); `Note.boardTitle` and `windowTitle` (`App/NoteView.swift:259-267`); the clamping math of `restoredFrame` (`App/Windows.swift:415-436`). Move their tests from AppTests to the package.

**L6. One alert helper and one menu bridge** (`refactor/alerts-and-menus`)
- **Do:** a `StowAlert.run` helper for the 16 `NSAlert()` sites; ProfileManager takes one injected `alert: (ProfileAlert) -> Bool`. ProfileSwitcher and OwnerMenuButton become configurations of `PullDownMenu`.
- **Tests:** existing profile tests, switched to the single closure; menus still run their actions.

**L7. Tasks that stop with their owner** (`refactor/owned-tasks`)
- **Do:** the refresh and accessory loops exit when the store is gone; refresh and accessory kicks go through stored tasks that `stop()` cancels; `Theme.swift:78-84` uses `MainActor.assumeIsolated`.

**L8. One model per note** (`perf/note-models`)
- **Do:** the [observed state design](#observed-state), without module slices yet. PRCard takes `isPinned`, `isExpanded`, `isLoading` and its notes as values. Rename `state` to `base` and add `snapshot()`.
- **Tests:** with `withObservationTracking`, typing notifies only that note; moving a window notifies nothing; a refresh notifies no note view. A scripted series of edits gives the same `snapshot()` as before. The persistence, merge and quit suites pass unchanged.

**L9. Remaining costs** (`perf/board-idle`, one commit each)
- Cache `textHeight` by width, limit and a text version (`App/NativeEditor.swift:96-115`).
- One board-level minute clock passed to rows, replacing a `TimelineView` per row.
- After each note write, record size and modification time; the watcher and presenter call `changed()` only when a listed `.md` differs.
- Skip an activation refresh within 60 seconds of the last attempt.
- Guard the no-op writes after a save: `saveError`, `conflictNoteIDs`, `accessoryResults`.
- Cache the relative date formatter per locale; memoize repository colors by repository and surface; stop the title scan at the first title line.
- Only if L10's numbers still show them: fetch known pull requests once per refresh, and record window frames at the end of a live resize.

**L10. Measure again and release 0.4.0**
- Rerun L1's script and tests; put before and after side by side in `docs/verification.md`.
- **The owner tests:** everything still works; Activity Monitor shows Stow near zero CPU when idle; typing stays smooth with many notes open.

### 0.5.0 Modules

Serial: M0 → M1 → M2 → M3 → M4 → M5. Nothing visible changes; parity is the gate.

**M0. Note link model, StowCore only** (`feat/note-link-model`)
- **Do:** the [note links design](modules.md#note-links). Nothing writes the new kinds yet. Add a synthetic `state.json` made by the v0.3.0 Debug build with `--stow-demo` as `Tests/StowCoreTests/Fixtures/state-0.3.0.json`, and add `resources` for it in `Package.swift`.
- **Tests:** the fixture re-encodes byte for byte; a 0.3.0-shaped decoder reads the new output; bad `moduleItem` and `webLink` values drop only the link; key precedence; backups round-trip web links and still reject a malformed pull request link.

**M1. SDK v2 values and a card adapter** (`feat/sdk-v2`)
- **Files:** `Sources/StowExtensionSDK/`, a new adapter in StowCore from `PullRequestSnapshot` to `ModuleCard`.
- **Tests:** every value round-trips through JSON and tolerates unknown keys. For the demo content and the core fixtures, the adapter's card matches today's section, headline, tone, notes, checks label, eyebrow, accent color, summary, facts and detail rows.

**M2. Module host** (`feat/module-host`)
- **Files:** `Sources/StowExtensions/` (`ModuleRegistry`, a `ModuleScheduler` actor), StowCore (`ModuleItemKey`, `FacetSelection`, `boardSections`, `notePlacements`, `AccentColor`, a `MachineSettings` protocol), App (a `UserDefaults` store, in memory for tests and testing-state runs).
- **Do:** everything under [what the host owns](modules.md#what-the-host-owns). Registry: API version 1 is an accessory, 2 a module, higher is unsupported. Machine settings: on the first 0.5.0 launch, adopt each known profile's `gh` path and GitHub switch once; after that, a profile with no entry on this Mac is off.
- **Tests:** no call ever reaches a disabled module; joining and follow-up refreshes; cancellation on each trigger; a timeout keeps the last good board; old revisions rejected; each cap rejects the result; an identity mismatch pauses and commits nothing; machine-local values never reach a backup; a copied-in `state.json` can't turn GitHub on or choose `gh`; `boardSections` matches today's owner functions, Show more and pins.

**M3. GitHubModule and the binding** (`feat/github-module`)
- **Files:** `Sources/StowGitHub/` (`GitHubModule`), `Sources/StowCore/` (`GitHubSchema1Binding`).
- **Tests:** module tests on the scripted transport; the paste tests pass through the link pattern, with GitHub off too; `state-0.3.0.json` round-trips byte for byte through the binding.

**M4. Run the board on modules** (`refactor/board-on-modules`)
- **Files:** `App/BoardView.swift`, `App/PRCard.swift` becomes `App/ModuleCardView.swift`, `App/OwnerControl.swift`, `App/SettingsView.swift`, `App/AppStore+GitHub.swift`.
- **Do:** the app reads cards from module slices. Keep the accessibility identifiers. At launch, wait up to a second for the first stale render before showing windows.
- **Tests:** a hosted test compares the old and new board for the same state before the old path is removed; the owner, cancellation, profile, sections and live-notes suites pass; accessibility audit; smoke test.

**M5. Remove the GitHub-specific host code** (`refactor/remove-github-host-code`)
- **Do:** delete what M4 replaced; move classification, card status and reconciling into StowGitHub. Update `docs/architecture.md` and `docs/providers.md`.

**Release 0.5.0.** **The owner tests:** real boards look and behave exactly as in 0.4.0 in every profile; a different `gh` account still pauses a profile; pins, dismissals and owner filters survive the update; downgrading to 0.3.1 and back keeps GitHub data.

### 0.6.0 Cards and notes

C1 first. Then C2 and C3→C4→C5 can run in parallel (notes and views against the GitHub module).

**C1. Sample module cards** (`feat/sample-cards`): the sample module returns synthetic cards from an `itemCount` setting; off by default; a test proves it makes no network call.

**C2. Notes under cards and web links** (`feat/notes-under-cards`)
- **Files:** `App/BoardView.swift`, `App/NoteView.swift`, `App/AppStore+Notes.swift`, `Sources/StowCore/Paste.swift`, `Sources/StowCore/Portability.swift`, `docs/portability.md`.
- **Do:** render a card's notes right after it, never inside the card view; `requestFocus` opens the section that holds the note; Notes' count excludes notes under cards; a link chip for web links with Add link and Remove link; "Copy with link" in the note's menu copies the text and the URL; pasting a URL with text outside an editor makes a web-linked note.
- **Tests:** placement in every case; the conflict copy keeps its link; a pasteboard test for Copy with link.

**C3. Watching section** (`feat/watching`): a shared host section `stow.watching`, titled Watching, after Waiting by default. The GitHub module puts pinned pull requests from others there, replacing the "Watching" reason in Waiting. Tests: section order with old saved layouts; a card is in exactly one section.

**C4. Pull requests you reviewed** (`feat/reviewed-prs`): a GitHub setting, off by default, "Keep pull requests you've reviewed". It adds one search per refresh, `is:pr is:open reviewed-by:@me -author:@me`. Cards go in Watching and say "Updated since your review" when the newest commit is later than your latest review. Check the fields with one query against a public repository before writing fixtures. Tests: the request count rises by exactly one, and only with the setting on.

**C5. Review activity on cards** (`feat/review-activity`)
- **Do:** add `reviewThreads(first:100){totalCount nodes{isResolved}}`, `comments(last:1){totalCount nodes{createdAt author{login}}}` and `reviews(last:1){nodes{submittedAt state author{login}}}` to the shared field list (`GHClient.swift:351-356`). The card shows "N unresolved", and a marker for activity by someone else that's newer than the last time you opened the card. Outline approved cards in repositories that don't require reviews. These fields are display-only: never part of readiness, classification or "state observed since".
- **Tests:** fixtures without the new keys still pass and read as unknown; the request count doesn't change; a marker clears when the card is opened.

**Release 0.6.0.** **The owner tests:** a note on a pull request sits under its card and moves to Notes when the card leaves; Copy with link pastes both; a web link on a note; Watching; a reviewed pull request showing an update; a new comment showing on a card.

### 0.7.0 Sticky notes

All five can run in parallel except S2 and S5, which both add note metadata (S2 first).

- **S1. Quick-note shortcut** (`feat/quick-note`): a global hot key through `RegisterEventHotKey`, which needs no Accessibility permission. Off by default, with a recorder in Settings. It opens a new detached note in the active profile.
- **S2. Note colors** (`feat/note-colors`): an optional `color` key on notes, decoded leniently; six colors plus the theme default; text keeps 4.5:1, checked with `RGBColor.contrast`.
- **S3. Menu bar item** (`feat/menu-bar`): an `NSStatusItem` with New Note, Show Board and recent notes. Off by default.
- **S4. Launch at login** (`feat/launch-at-login`): `SMAppService.mainApp`, off by default. If registering fails on an unsigned build, show the error and point to Login Items in System Settings.
- **S5. Secure notes** (`feat/secure-notes`)
  - The secret is a Keychain generic password keyed by the note's UUID, behind an injected `SecretStore` protocol. The note's metadata holds a title and an optional expiry.
  - It never reaches a Markdown file, `state.json`, a backup, an export, a window title or a board summary.
  - Masked until clicked. Copy marks the pasteboard `org.nspasteboard.ConcealedType` and clears it after 60 seconds if unchanged.
  - Expiry of an hour, a day, a week or never; the Keychain item goes when the note expires or is deleted.
  - Tests: an in-memory store; the secret appears in no file under the data folder and in no backup; clipboard clearing; expiry.
  - Known limit: an unsigned build's identity changes with each version, so macOS may ask about Keychain access again after an update.

**Release 0.7.0.** **The owner tests:** each of the five by hand, with every module off too; a secure note after updating to the next build.

### 0.8.0 Install and polish

I1 and I2 in parallel; I3 last.

- **I1. Move to Applications** (`feat/installer`)
  - **Files:** `App/Windows.swift:140-149`, a new `App/Installer.swift`.
  - Offer the move after the app lock is taken and before any profile opens, only when the state folder is the default one and demo is off.
  - Find the real location of a translocated app with `SecTranslocateCreateOriginalPathForURL` through `dlsym`, falling back to `statfs`'s `f_mntfromname`.
  - Copy from a DMG, move from Downloads. Launch the new copy with the old process id; it waits for that process to exit before taking the lock.
  - The new copy ejects the volume, then moves the DMG to the Trash: only a `Stow-*.dmg` that `hdiutil info -plist` reports for that mount point, and only if the eject worked. Inject the Trash and eject calls for tests.
  - Keep the quarantine flag. A standard user without rights to `/Applications` gets a message instead.
  - Tests: location detection for each case; the offer never shows in testing or demo runs; the wait-then-lock order. The owner runs the real flow from a downloaded DMG on both Macs.
- **I2. Smoothness** (`feat/motion`): one motion helper and a custom environment key so tests can switch it off. Animate a note opening and closing, the composer, pull request details and the update notice. Wrap `isEditing = editing` (`App/NoteView.swift:94`) but never typing growth. Replace the fixed `settle()` waits in hosted tests with condition polling.
- **I3. Accessibility pass:** keyboard navigation through every control, VoiceOver labels, and a physical external display; record results and fix what they find.

**Release 0.8.0.** **The owner tests:** installing from the DMG on both Macs; Reduce Motion on and off; the board with only the keyboard.

### 1.0.0 Stable

- **V1. Schema 2** (`feat/schema-2`): `currentVersion` becomes 2. GitHub's data moves to the generic `modules`, `itemPins`, `itemDismissals` and `facets` keys, and the machine-local mirror is no longer written. The first save backs up the schema-1 file. Delete the binding; StowGitHub then depends only on the SDK. Tests: migrating the 0.3.0 fixture; an older build preserves a schema-2 file instead of overwriting it; restoring from the backup.
- **V2. Release candidate:** published as a pre-release. For about two weeks, fixes only, with no data-loss reports.
- **V3. Docs and site:** drop "Alpha" from the README, install guide and site; describe modules and the bare notes setup.
- **V4. 1.0.0:** the first release not marked pre-release. From then the update check offers stable versions only.

## After v1 (not scheduled)

- A status module: uptime for your own sites and status pages such as GitHub's, with notifications.
- An iPhone and iPad app with widgets, which needs sync designed first.
- Developer ID signing and notarization, then installing updates from inside Stow.
- Installable modules, a GitHub account per profile, themes that follow light and dark, compact mode, a command palette, one text config.

To keep those possible: StowCore and the SDK stay Foundation-only, module values stay plain data, notes stay Markdown files, and `gh` stays behind the GitHub module's own transport.

## Verification for every release

- `./scripts/test.sh`, `./scripts/build.sh Debug` and `Release`, the smoke test, `./scripts/accessibility.sh`.
- The `acceptance` label on the version PR for the Intel run.
- The owner's hands-on list for that release, on Apple silicon and the Intel Mac.
- A dated `docs/verification.md` entry with counts, what ran and what didn't.
- Release-specific gates: before-and-after numbers (0.4.0); board parity and the byte-identical fixture (0.5.0); a downgrade from the backup (1.0.0).
