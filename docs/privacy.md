# privacy and recovery

## local data

Stow stores its local setup in `~/Library/Application Support/Stow/`. `state.json` is a metadata index containing note links, window state, settings, pins, dismissals, the last connected login, accessory configurations, and cached pull-request metadata and expanded details. It points to the current managed notes folder; note bodies are separate plaintext `<UUID>.md` files. New setups use `notes/`; restores can select a versioned `notes-<UUID>/` folder.

Use Settings → **Show data folder**, **Open notes folder**, or a note's **Show Markdown file** action to reveal the relevant location. Do not manually rename managed note files. Private repository titles, comments, branch names, note contents, and module settings can remain on disk, including in retained backups.

There is no analytics, telemetry, cloud sync, or Stow account. Notes are not sent to GitHub. Markdown preview uses image placeholders without fetching remote images. GitHub requests use the existing GitHub CLI login when enabled. Opening a link launches the system browser. Stow currently supports `github.com` only.

The JSON index and Markdown files are not application-encrypted. New storage directories use owner-only permissions, and files are created owner-readable and owner-writable before receiving bytes. Existing directory permissions are preserved. System backups, other software with account access, external editors, and trusted accessories may still access local data.

Turning off GitHub hides cards and stops new refreshes without erasing the cache. Changing accounts clears the previous account's cache after a successful refresh; personal notes remain. Do not share the data folder or state index when reporting a problem.

## credentials and trusted code

Authenticate with `gh` outside Stow. Stow invokes the CLI directly, does not extract credentials, and does not persist a token. Process response bodies and stderr are not logged. Do not add logging of API payloads or environment variables.

The app is not sandboxed because it launches the external CLI. Bundled accessories are trusted in-process code; the SDK is not a permission boundary. Module configuration is opaque data and may contain private values. See [provider trust](providers.md#portability-and-trust).

## backup and recovery

Use Settings → **Save backup…** for a portable `.stowbackup` containing notes and the complete setup. Note exports and full backups synchronize live edits first and are refused if synchronization fails. A full backup is plaintext and can include private cached PRs, account identifiers, and sensitive module configuration. Markdown exports and appearance configs serve different purposes; see [notes, configs, and backups](portability.md).

Restore validates the backup, previews note and cached-PR counts, and asks before replacing current data. It saves a full pre-restore backup, writes a new private notes folder, then atomically publishes an index pointing to it. The previous notes folder and raw index are retained. A failed restore leaves the previous setup untouched. Reopen notes in external editors after restoring; an old file URL points to a retained backup folder that is no longer watched.

For a manual filesystem backup, quit Stow and copy the entire Application Support `Stow` folder, including the index, its referenced notes folder, and retained backups. Do not restore `state.json` alone: the current index contains no note bodies and may point to another folder. Prefer the app's `.stowbackup` restore action for transferring a complete setup.

The first save of a legacy JSON setup migrates note bodies into Markdown and preserves a private copy of the old JSON. Damaged, unreadable, or unsupported state blocks ordinary replacement writes. Explicit recovery preserves the index and managed notes folder before starting fresh; it does not repair or import those backups. Keep all migration, recovery, and pre-restore copies private.

If saving fails, keep Stow open to retain edits and check disk space and folder access. Choose **Keep open** on quit unless you intend to discard unsaved changes. Do not delete the data folder as routine troubleshooting.

## repository hygiene

Use synthetic fixtures and screenshots. Keep real notes, API responses, internal domains, network addresses, credentials, machine paths, logs, and local state out of commits and CI uploads. CI scans full fetched history and the working tree with redacted Gitleaks output. A clean scan complements review; it does not prove every file is safe to publish.
