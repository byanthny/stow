# working in stow

## scope and conventions

- Target macOS 14 or later and Swift 6. Keep the native app small and the package modules testable without launching it.
- Use short, direct prose. README headings use title case; other documentation keeps lowercase headings. Use conventional commit subjects such as `feat(notes): restore detached windows`.
- Preserve the existing Git identity, signing setup, configuration, and hooks. Build and test commands must not modify them.
- Keep `project.yml` and the checked-in Xcode project in sync when changing app targets or dependencies. Preserve pinned package resolution.

## invariants

- Managed UTF-8 `<UUID>.md` files are the canonical note sources; `state.json` holds metadata without duplicating note bodies. Preserve both versions of detected external-edit conflicts. Closing a window must not delete a note. Flush the final edit before quitting and preserve data when saving fails.
- Preserve corrupt, unreadable, or newer saved state. Only the explicit recovery action may move it to a backup before creating replacement state.
- Hold `StateLock` before writing a state folder; a second process hands over instead of writing. Backups omit machine-local settings and restore keeps this Mac's values: a received backup must never choose a program to launch or turn GitHub or accessories on. New installations ask before using GitHub.
- Unknown, missing, partial, or stale GitHub data must never imply readiness. Keep the last good cached card on incomplete refreshes. Account changes must not relabel another account’s cache.
- Invoke `gh` directly with arguments and structured input, and only at paths `GHClient.isUsableExecutable` accepts. Never read its token, use a shell for API requests, or log private response bodies.
- The SDK exchanges versioned `Codable` and `Sendable` values. Keep SwiftUI, AppKit, app state, and host-specific rendering out of its public contract.
- Accessories are optional trusted code. Disabled providers must not run. Cancellation, timeout, stale-result rejection, unavailable-provider handling, and configuration preservation belong in the host.
- Keep the sample provider synthetic, disabled by default, and free of network access. There is no weather feature.

## privacy

Use synthetic notes, pull requests, fixtures, and screenshots. Do not commit real notes, cached API responses, credentials, internal domains, network addresses, machine-specific absolute paths, live logs, or local state. Review staged files before committing. Do not upload local app data or raw logs as CI artifacts.

## checks

Run from the repository root with Xcode 16.4 or later selected:

```sh
./scripts/test.sh
./scripts/build.sh Debug
./scripts/build.sh Release
```

`scripts/test.sh` runs Swift package tests and hosted app tests with local ad-hoc signing. Keep the app test host isolated from normal user state. `swift test` runs the package tests directly. For UI changes, run `./scripts/accessibility.sh`: it audits the Debug app with synthetic state through UI automation, needs Automation Mode, and moves the pointer while it runs. For packaging changes, run `./scripts/package.sh` and verify the emitted checksum and app architectures. Use the manual checks in `docs/verification.md` for UI, persistence, and platform behavior. Record observed results and limitations; passing automated tests does not prove the app’s full user flow.
