# verification

Record the toolchain, macOS version, commands, and observed result for each validation run. Keep logs and screenshots local, using synthetic data. Do not publish real state or API responses.

## automated checks

```sh
./scripts/test.sh
./scripts/build.sh Debug
./scripts/build.sh Release
./scripts/package.sh
```

The package suite covers classification, paste parsing, persistence and recovery, cache reconciliation, mocked GitHub pagination and partial responses, refresh coordination, and the accessory contract and cancellation. The test script also runs hosted app tests through the Stow scheme with local ad-hoc signing. The app detects the test host before normal startup so these tests cannot load the normal state folder. Builds check compilation of the native app. Packaging verifies the ad-hoc signature and both executable architectures, strips build-machine debug paths before signing, then emits a ZIP checksum. None of these checks establishes a real-account GitHub flow or complete UI acceptance.

CI uses Xcode 16.4 on `macos-15`, runs package and hosted Debug app tests, and builds universal Release. The hosted test step already builds Debug, so a duplicate Debug build is omitted. Hosted tests use ad-hoc signing without a development team or signing credential. A Linux job scans history and files with Gitleaks 8.30.1. Native checks run after it only for code, project, dependency, script, or workflow changes, plus explicit manual runs. Push builds cover `main`; feature branches run through their PR, avoiding duplicate push/PR builds. It does not sign for distribution, notarize, authenticate with GitHub as a user, or upload app data.

## manual acceptance

- Start with synthetic state. Create, edit, preview, detach, close, reopen, and explicitly delete notes. Verify selection, undo, copy/paste, Markdown links, and the last edit after quit and restart.
- Keep multiple detached notes open. Change each note’s always-on-top setting. Hide and reopen the board through the Dock and Command-0. Confirm window restoration on one display and after disconnecting another display.
- Disable GitHub and verify notes-only use. Test missing `gh`, authentication failure, offline refresh, inaccessible pins, rate limits, partial responses, and an account switch. Preserve cached content and keep incomplete readiness conservative.
- With a deliberately authorized test account, verify authored PRs, direct review requests, pin/dismiss/restore, lazy details, and browser links against GitHub. Use synthetic repositories for shareable evidence.
- Enable the sample on the board and one note. Disable each while refreshing. Confirm other content remains usable and unavailable module settings survive restart.
- Edit a managed Markdown file in another editor, including an atomic save; verify source reload, detected conflict copies, clean external deletion, and immediate quit. Export notes and a full backup; restore into disposable state and check the retained old folder, restored windows, pins, and appearance. Reopen external-editor files after restoration.
- In a disposable state directory, test corrupt and unsupported state. Confirm writes stay blocked, explicit recovery creates a backup, and failed recovery preserves the original. Test an unwritable destination without changing normal user storage.
- Check keyboard navigation, VoiceOver labels, text scaling, contrast, a 320-point board width, and a 260-point detached note width.
- Verify appearance changes, theme import/export, opacity, Reduce transparency, and text-editing preservation using the [appearance checklist](appearance.md#manual-checks). Collapse and expand Needs you and Waiting, then relaunch to check persistence. In Settings → Board, reorder sections, change the cards shown before Show more, and allow Notes to collapse; creating a note should expand Notes again. Scroll a long board and confirm section titles stay pinned.
- Run on macOS 14 and a current macOS version. A newer build host does not prove minimum-version runtime behavior. Test Intel hardware when available; a universal binary alone does not prove its runtime behavior.

## evidence

Local validation on macOS 26.5 (Apple silicon), using Xcode 26.6:

- `./scripts/test.sh` passed 138 tests: 60 core XCTest cases, 45 Swift Testing cases for themes/GitHub/accessories, and 33 hosted AppKit cases. Coverage includes saved section state, live font changes preserving source/selection/undo, background-only opacity, independent persisted board/note pinning, the Markdown image-network tripwire, legacy storage migration, live Markdown reloads from in-place and atomic external saves, conflicts and deletion handling, fresh export snapshots, private transfer files, and backup restoration with window reconstruction. It also covers restores that keep this Mac's GitHub settings and turn restored accessories off, `gh` path checks, bounded lazy details, the single-writer lock, and the first-launch GitHub opt-in.
- A fresh synthetic Debug launch passed 12 workflow checks and exited normally after flushing the last edit. These exercise detachment, close-without-deletion, independent window level, board reopening through the application delegate, paste, accessories, notes-only use, and persisted restoration data. Hosted tests reconstruct windows; these are not physical desktop interaction checks.
- On 2026-11-03 a universal Debug build (arm64 and x86_64) passed the same 12 smoke checks on this Mac. A second launch against the same synthetic state exited at once, brought the running copy forward, and left `state.json` unchanged.
- A Finder-style launch with the ordinary application search path found the installed `gh` and reused its authentication. Three real pull requests matched independent API checks for title, state, draft, mergeability, merge state, review decision, and checks summary. Live state and responses stayed outside Git. Cached restart/offline behavior and pin retention also have synthetic coverage.
- The universal Release build and local ZIP passed architecture, ad-hoc signature, and SHA256 checks. Synthetic board and settings captures were visually inspected before inclusion in the README.

One packaged Release launch with two synthetic notes, three cached PR cards, a failing `gh` stub, and a warm filesystem measured 248 ms from process entry to the first-board callback. RSS after five seconds was 105.3 MiB; the CPU snapshot was 0.1%. The app bundle was 9,725,976 bytes and the ZIP 2,820,745 bytes. This is one local sample, not a cold-start benchmark or a long-term idle profile.

The initial native commit also passed the pinned Xcode 16.4 CI run: package and hosted tests, Debug, universal Release, and secret scans. CI checks for later commits are recorded on the PR.

Hands-on acceptance on 2026-11-03, macOS 26.5 on Apple silicon with the built-in display, using the universal Debug build and synthetic state:

- Spaces: the board follows desktop switches. Passed.
- Full-screen apps: Stow windows stay out of other apps' full-screen spaces. That is the intended behavior, so windows no longer request full-screen auxiliary placement.
- Dock and focus: the board reopens from the Dock and Command-0, and a note takes focus again after switching apps. Passed.
- First-launch GitHub prompt: fresh state without demo data shows the card and it behaves as designed. Passed.
- Skipped by the maintainer for now: keyboard navigation, VoiceOver, Reduce transparency and Increase contrast, and minimum widths.

Still pending: monitor changes with an external display, Intel runtime behavior (hardware is available, and the on-demand `acceptance` workflow runs the smoke checks on x86_64), keyboard navigation, VoiceOver and display accessibility settings, and extended idle/typing measurements. macOS 14 runtime behavior is untested: GitHub retired its `macos-14` runners on 2026-11-02, and no macOS 14 machine is available. The current machine and hosted tests do not establish those results.
