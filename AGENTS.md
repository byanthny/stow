# working in stow

## scope and conventions

- Target macOS 14 or later and Swift 6. Keep the native app small and the package modules testable without launching it.
- Use short, direct prose and lowercase documentation headings. Use conventional commit subjects such as `feat(notes): restore detached windows`.
- Preserve the existing Git identity, signing setup, configuration, and hooks. Build and test commands must not modify them.
- Keep `project.yml` and the checked-in Xcode project in sync when changing app targets or dependencies. Preserve pinned package resolution.

## invariants

- Notes have one canonical persisted representation. Closing a window must not delete a note. Flush the final edit before quitting and preserve data when saving fails.
- Preserve corrupt, unreadable, or newer saved state. Only the explicit recovery action may move it to a backup before creating replacement state.
- Unknown, missing, partial, or stale GitHub data must never imply readiness. Keep the last good cached card on incomplete refreshes. Account changes must not relabel another account’s cache.
- Invoke `gh` directly with arguments and structured input. Never read its token, use a shell for API requests, or log private response bodies.
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

`scripts/test.sh` runs Swift package tests and hosted app tests with local ad-hoc signing. Keep the app test host isolated from normal user state. `swift test` runs the package tests directly. For packaging changes, run `./scripts/package.sh` and verify the emitted checksum and app architectures. Use the manual checks in `docs/verification.md` for UI, persistence, and platform behavior. Record observed results and limitations; passing automated tests does not prove the app’s full user flow.
