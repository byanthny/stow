# Architecture

Stow separates local state, GitHub reads, portable accessories, and the macOS interface.

| component | responsibility |
| --- | --- |
| `StowCore` | models, live Markdown storage and metadata index, transfer codecs, paste parsing, attention classification, cache reconciliation, and update versions, policy, and settings |
| `StowGitHub` | GitHub CLI process transport, GraphQL decoding and pagination, refresh coordination, and lazy details |
| `StowUpdates` | the update check's one request: a release list read without cookies, credentials, or cache |
| `StowExtensionSDK` | plain versioned request, descriptor, configuration, and snapshot values plus `AccessoryProvider` |
| `StowExtensions` | provider registry, validation, timeout, cancellation, cache, and adapters |
| `StowSampleExtension` | optional synthetic provider with no network or host-state dependency |
| `StowCore` profiles | profile identity, the index, discovery, deletion to the Trash, and owner selection and grouping |
| `App` | AppKit lifecycle and panels, SwiftUI rendering, native text editing, and observable orchestration |

## State and windows

`AppStore` owns the in-memory `AppState`. Board and detached windows reference one note by stable ID. A managed `<UUID>.md` file is the canonical Markdown source. The live `state.json` envelope uses disk schema version 2: `metadata` holds an `AppState` with empty note bodies, and `notesDirectoryName` names the validated managed notes directory. It retains links, frames, detached state, pins, dismissals, settings, board layout preferences, cached PRs, and accessory configuration.

`StateLock` holds an exclusive lock on a private file beside the index for the process lifetime, so only one process writes a state folder; the kernel releases it on exit or crash, and a second launch activates the running copy instead. `StateRepository` serializes persistence and uses coordinated file access with private temporary files and atomic replacement. The app serializes its persistence chain and debounces edits. An FSEvents watcher debounces external changes into a merge that compares disk sources with baselines and locally dirty notes. Detected conflicts preserve both versions as separate notes; clean external deletions remove notes while unsaved edits are preserved. Coordination cannot eliminate every race with an uncooperative editor.

Quit performs a final merged save before closing the writer. Source versions adopted by the repository but not yet acknowledged by the UI remain protected through subsequent saves and quit, so a stale UI snapshot cannot silently overwrite them. A failed flush lets the user keep the app open. Unsupported or damaged state blocks ordinary writes until repair or explicit backup recovery.

The first successful save of legacy JSON storage backs up the old index and migrates its note bodies to Markdown. Full restore writes all replacement sources into a new private `notes-<UUID>` folder, retains the previous folder and raw index, and atomically publishes the new index pointer. The host also saves a complete pre-restore backup. Watchers and file-reveal actions follow the current resolved directory; external editors must reopen files after restore.

The `.stowbackup` codec uses backup format version 1 and encodes a complete in-memory `AppState` snapshot, including note bodies, for explicit transfer and restore. Machine-local settings, the `gh` location and the GitHub switch, are written as defaults and keep this Mac's values on restore; restored accessories start disabled. `GHClient` launches only an absolute path named `gh` that resolves to a regular executable other users cannot write. That envelope is separate from the metadata-only live disk index. The host synchronizes live edits before note exports or backup snapshots and refuses the transfer if synchronization fails. Markdown import validates all selected files before adding new note identities; exports are independent copies. See [portability](portability.md) and [privacy and recovery](privacy.md).

## Profiles

A profile is one state folder with its own `state.json`, notes folder, `.stow.lock`, and retained backups. The first profile is the data folder itself and is named "Stow"; others live in `profiles/<UUID>/`. Each profile folder can hold an `identity.json` with the profile's ID, name, color, and optional icon. `ProfileCatalog` finds profiles by looking at the folders, not at the index. It treats identity files and the index as untrusted input: sizes are limited, IDs must be UUIDs matching their folder, links and folders owned by another user are ignored, and names are sanitized.

`profiles.json` in the data folder is a small index of profile order, which profiles were open or hidden at quit, the most recently active profile, the IDs already seen, and app-wide display and update settings. It is created only when there is something to record. A corrupt or newer index is preserved, and **Reset profile list** moves it to a backup before writing a new one.

One process opens any number of profiles. `.stow-app.lock` is held for the process lifetime and decides whether a second launch hands over. Each open profile takes its own `.stow.lock`; if another process holds it, such as an older build using the first profile, that profile stays closed. `ProfileManager` owns the open sessions. Each `ProfileSession` has its own store, theme, GitHub client, refresh coordinator, accessory host, watcher, and windows, so nothing in one profile reads another's state. Profiles using the same `gh` location share one client and its rate-limit backoff. Hide, show, close, and switching act on a profile's windows together; hidden and closed profiles do not poll or run accessories.

Deleting a profile moves its folder to the Trash; the first profile is moved into `profiles/<id>/` first, with a journal so an interrupted move is finished or undone at the next launch. Stow never deletes profile data outright.

A profile folder Stow has not seen before opens with GitHub and accessories off and no saved `gh` location. Each profile remembers the login it last refreshed as. A refresh that answers as a different login is discarded and pauses the profile until the user chooses **Use X here**, which clears that profile's cached pull requests, details, and dismissals and keeps pins and notes.

Owners are the repository owners in pull request references, compared ignoring case. Each profile saves an owner selection that changes only what is visible; classification, warnings, pins, and refreshes are unaffected. Grouping and order are per-profile board layout settings. See the [profile design](profiles.md).

## GitHub reads

`GHProcessTransport` starts `gh api` directly for `github.com`, supplies JSON over standard input, and drains process output with bounded buffers. It reuses the CLI’s existing authentication and sanitizes user-facing errors. Stow does not have a token store.

`GHClient` discovers the authenticated viewer, fetches authored and directly requested pull requests, resolves pins, paginates connections, and loads details on demand. Details fetch at most three pages per connection and keep at most 100 checks and 100 reviews, preferring checks that need attention, so a very large pull request cannot bloat the saved index. A new installation leaves GitHub off until the user opts in. `RefreshCoordinator` coalesces overlapping refreshes. The app refreshes on activation and periodically while GitHub is enabled.

Classification distinguishes observed facts from incomplete readiness. Conflicts, requested changes, failing checks, direct review requests, and complete merge readiness can need attention. Draft and terminal states override readiness. Unknown checks, mergeability, review data, or incomplete pagination cannot establish “Ready to merge.” “Behind base branch” is informational. Pins preserve watched cards; dismissals hide cards without deleting notes. Terminal unpinned cards expire 24 hours after first observation.

## Update check

`ReleaseFeed` in `StowUpdates` makes the one request Stow sends without `gh`, and only after the person turns on Settings → Updates or chooses **Check for updates…**. It uses an ephemeral `URLSession` with no cookies, credentials, or cache, fixed headers, and a 30-second limit, and reads at most 1 MiB. Everything else is plain values in `StowCore`. A `ReleaseSource`, Stow's by default, names the release list and the only pages a release may link to: under `https://github.com/byanthny/stow/releases/`, with no dot segments. An `UpdatePolicy` decides when a check is due and which release to offer: release tags compare as Semantic Versioning, and pre-releases count only until a stable release is out. `UpdateSettings.record` turns a check's result into what the board offers, keeping the earlier release when a check fails. `UpdateMonitor` in the app runs one check at a time: at launch and then at most daily while the setting is on, or when asked. It keeps the setting and the last result in `profiles.json`; the board shows a notice until it is dismissed or that version runs. Nothing downloads.

Older Stow versions don't know the update settings, so one that rewrites `profiles.json` drops them, and a damaged value reads as off. Either way, checks stay off until turned on again.

## Dependency direction

The SDK depends only on Foundation. Core may store SDK configuration values, but providers receive only their explicit request. The host owns placement and rendering. The app links the modules; module tests do not depend on the app.

The JSON adapter exercises a serialization boundary in-process. It does not launch an executable, isolate code, or promise a stable binary ABI. A later host may carry the same values over a process transport without introducing macOS view types into the contract.
