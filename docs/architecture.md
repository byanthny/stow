# architecture

Stow separates local state, GitHub reads, portable accessories, and the macOS interface.

| component | responsibility |
| --- | --- |
| `StowCore` | persisted models, atomic state storage, paste parsing, attention classification, and cache reconciliation |
| `StowGitHub` | GitHub CLI process transport, GraphQL decoding and pagination, refresh coordination, and lazy details |
| `StowExtensionSDK` | plain versioned request, descriptor, configuration, and snapshot values plus `AccessoryProvider` |
| `StowExtensions` | provider registry, validation, timeout, cancellation, cache, and adapters |
| `StowSampleExtension` | optional synthetic provider with no network or host-state dependency |
| `App` | AppKit lifecycle and panels, SwiftUI rendering, native text editing, and observable orchestration |

## state and windows

`AppStore` owns the in-memory `AppState`. Views reference notes by stable ID. A detached window edits the same note as the board. Note text, links, detached state, window frames, pins, dismissals, settings, cached pull requests, and accessory configuration are persisted together through the `StateRepository` actor.

Edits schedule a debounced save. Quit requests a final flush and keeps the app open if the user declines to discard unsaved changes. Writes create a private temporary file before atomically replacing the state file. Unsupported or damaged state blocks writes until explicit backup recovery. See [privacy and recovery](privacy.md).

## github reads

`GHProcessTransport` starts `gh api` directly for `github.com`, supplies JSON over standard input, and drains process output with bounded buffers. It reuses the CLI’s existing authentication and sanitizes user-facing errors. Stow does not have a token store.

`GHClient` discovers the authenticated viewer, fetches authored and directly requested pull requests, resolves pins, paginates connections, and loads details on demand. `RefreshCoordinator` coalesces overlapping refreshes. The app refreshes on activation and periodically while GitHub is enabled.

Classification distinguishes observed facts from incomplete readiness. Conflicts, requested changes, failing checks, direct review requests, and complete merge readiness can need attention. Draft and terminal states override readiness. Unknown checks, mergeability, review data, or incomplete pagination cannot establish “Ready to merge.” “Behind base branch” is informational. Pins preserve watched cards; dismissals hide cards without deleting notes. Terminal unpinned cards expire 24 hours after first observation.

## dependency direction

The SDK depends only on Foundation. Core may store SDK configuration values, but providers receive only their explicit request. The host owns placement and rendering. The app links the modules; module tests do not depend on the app or MarkdownUI.

The JSON adapter exercises a serialization boundary in-process. It does not launch an executable, isolate code, or promise a stable binary ABI. A later host may carry the same values over a process transport without introducing macOS view types into the contract.
