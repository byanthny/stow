# Privacy and recovery

## Local data

Stow stores its local setup in `~/Library/Application Support/Stow/`. `state.json` is a metadata index containing note links, window state, settings, pins, dismissals, the last connected login, accessory configurations, and cached pull-request metadata and expanded details. It points to the current managed notes folder; note bodies are separate plaintext `<UUID>.md` files. New setups use `notes/`; restores can select a versioned `notes-<UUID>/` folder. A private `.stow.lock` file lets only one Stow process write a profile's data at a time. A separate `.stow-app.lock` decides whether a second launch hands over to the running copy.

## Profiles

The folder above is the first profile, named "Stow". Additional profiles live in `profiles/<UUID>/` inside it, each with its own `state.json`, notes, `.stow.lock`, and backups. A profile folder can hold an `identity.json` with its name, color, and optional icon. A small `profiles.json` index records profile order, which profiles were open at quit, and display settings; it holds no notes, cards, or account data. A `.stow-app.lock` file lets only one Stow process run at a time, and each profile has its own lock.

Profiles organize work; they are not a security boundary. Every profile lives in the same macOS account, and anything with access to that account can read all of them. Profile names appear in window titles, which apps with screen-recording or accessibility access can read.

Deleting a profile moves its folder to the Trash, where it stays readable until you empty the Trash. Stow never deletes profile data outright.

A profile's backup contains only that profile, but it includes cached cards from every owner the account can see. Turn on Settings → Board → **Keep only selected owners on disk** to leave other owners' cards out of the profile's files and future backups. Backups saved before you turned it on still contain them. Restoring a backup on another Mac can otherwise carry private pull-request titles there. Dismissals stay either way: `state.json` and backups keep each dismissed pull request's ID, which names its owner and repository, including other owners'. Opening the profile in an older build of Stow turns the setting off.

Every profile uses the account `gh` is signed in as. If a refresh answers as a different account, Stow discards the result, pauses that profile's GitHub use, and asks before clearing its cached cards. A new profile, or a profile folder Stow has not seen before, starts with GitHub and accessories off.

Use Settings → **Show data folder**, **Open notes folder**, or a note's **Show Markdown file** action to reveal the relevant location. Do not manually rename managed note files. Private repository titles, comments, branch names, note contents, and module settings can remain on disk, including in retained backups.

There is no analytics, telemetry, cloud sync, or Stow account. Notes are not sent to GitHub. Notes show Markdown as text and never fetch images or links. GitHub is off on a new installation until you choose **Use GitHub**; requests then use the existing GitHub CLI login. Opening a link launches the system browser. Stow currently supports `github.com` only.

The JSON index and Markdown files are not application-encrypted. New storage directories use owner-only permissions, and files are created owner-readable and owner-writable before receiving bytes. Existing directory permissions are preserved. System backups, other software with account access, external editors, and trusted accessories may still access local data.

Turning off GitHub hides cards and stops new refreshes without erasing the cache. If GitHub answers as a different account, the profile pauses and keeps the old cards marked stale; choosing **Use X here** clears that profile's cached cards, details, and dismissals, and personal notes and pins remain. Do not share the data folder or state index when reporting a problem.

## Credentials and trusted code

Authenticate with `gh` outside Stow. Stow invokes the CLI directly, does not extract credentials, and does not persist a token. Process response bodies and stderr are not logged. Do not add logging of API payloads or environment variables.

The app is not sandboxed because it launches the external CLI. Bundled accessories are trusted in-process code; the SDK is not a permission boundary. Module configuration is opaque data and may contain private values. See [provider trust](providers.md#portability-and-trust).

## Backup and recovery

Backups are per profile. Use a profile's Settings → **Save backup…** for a portable `.stowbackup` containing that profile's notes and complete setup; it never holds the profile list or another profile. Note exports and full backups synchronize live edits first and are refused if synchronization fails. A full backup is plaintext and can include private cached PRs, account identifiers, and sensitive module configuration. It omits the `gh` location chosen on this Mac, a restore keeps this Mac's GitHub settings, and restored accessories start turned off. Markdown exports and appearance configs serve different purposes; see [notes, configs, and backups](portability.md).

Restore validates the backup, previews note and cached-PR counts, and asks before replacing current data. It saves a full pre-restore backup, writes a new private notes folder, then atomically publishes an index pointing to it. The previous notes folder and raw index are retained. A failed restore leaves the previous setup untouched. Reopen notes in external editors after restoring; an old file URL points to a retained backup folder that is no longer watched.

For a manual filesystem backup, quit Stow and copy the entire Application Support `Stow` folder, including the index, its referenced notes folder, retained backups, and the `profiles/` folder that holds every other profile. Do not restore `state.json` alone: the current index contains no note bodies and may point to another folder. Prefer the app's `.stowbackup` restore action for transferring a complete setup.

The first save of a legacy JSON setup migrates note bodies into Markdown and preserves a private copy of the old JSON. Damaged, unreadable, or unsupported state blocks ordinary replacement writes. Explicit recovery preserves the index and managed notes folder before starting fresh; it does not repair or import those backups. Keep all migration, recovery, and pre-restore copies private.

If saving fails, keep Stow open to retain edits and check disk space and folder access. Choose **Keep open** on quit unless you intend to discard unsaved changes. Do not delete the data folder as routine troubleshooting.

## Repository hygiene

Use synthetic fixtures and screenshots. Keep real notes, API responses, internal domains, network addresses, credentials, machine paths, logs, and local state out of commits and CI uploads. CI scans full fetched history and the working tree with redacted Gitleaks output. A clean scan complements review; it does not prove every file is safe to publish.
