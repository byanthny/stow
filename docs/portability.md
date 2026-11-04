# notes, configs, and backups

Stow keeps live notes as Markdown, offers independent exports, and can back up the complete local setup. Theme configs share appearance separately.

## live markdown files

New setups store notes in `~/Library/Application Support/Stow/notes/<UUID>.md` as ordinary UTF-8 source, without added frontmatter. After a restore, the current folder can be a versioned `notes-<UUID>` folder. `state.json` points to that folder, indexes note metadata, and stores window, pull-request, appearance, and accessory settings without duplicating Markdown bodies.

Use **Open notes folder** in Settings or a note's **Show Markdown file** action to reveal the current location. Keep UUID filenames unchanged; do not manually rename files within a managed folder.

The first save of an older JSON-based setup migrates its notes to managed Markdown files and keeps a private backup of the old state. Keep that backup until you have checked the migrated notes.

You can edit a managed note in another editor. Stow reloads external changes. When it detects a conflict with unsaved edits, it preserves both versions as separate notes. This does not guarantee race-free behavior with an editor that writes concurrently without coordination.

Use Stow's import action for arbitrary external Markdown files instead of dropping them into the managed folder. Deleting a note in Stow removes both the note and its managed file. A clean external file deletion removes the note from Stow; pending unsaved changes are preserved instead of silently discarded.

## import and export

- **Export Markdown…** saves one note as ordinary UTF-8 `.md` source, without adding Stow metadata.
- Bulk export creates a new folder with safe, unique filenames and never overwrites an existing folder.
- Exports are independent copies. Stow does not watch the export folder or update those copies.
- Import creates new notes with new IDs and leaves source files unchanged. Every selected file must be valid UTF-8 and no larger than 8 MiB; all are validated before any notes are added.

Before exporting notes or saving a full backup, Stow synchronizes live edits. If synchronization fails, the transfer is refused. Markdown copies do not preserve window placement, linked pull-request metadata, or accessory settings. Keep them private when their contents are private.

## appearance configs

Use **Copy config**, **Edit config…**, or `.conf` import/export to share short `key = value` appearance settings. These configs contain no notes or cached pull requests. See [appearance](appearance.md).

## full backup and restore

**Save backup…** creates a versioned `.stowbackup` JSON snapshot containing note contents and the complete local setup: cached pull requests and details, pins, dismissals, settings, module configuration, appearance, and window state. It does not extract GitHub CLI credentials. Settings that describe the Mac rather than your setup stay local: a backup omits the chosen `gh` location, and a restore keeps this Mac's GitHub settings, so a backup from someone else cannot pick a program for Stow to run or turn GitHub on. Accessories keep their configuration but come back turned off.

Backups are plaintext and are not encrypted. They can contain private notes, repository details, account identifiers, and sensitive module settings. Store full backups, migration backups, and pre-restore backups privately; do not commit or publicly attach them. Saving a backup in a synced cloud folder is fine, but it stays plaintext there: the provider and anyone the folder is shared with can read it.

Restore validates format, version, and data, previews note and cached pull-request counts, and asks for confirmation because it replaces the current setup. It saves a full pre-restore `.stowbackup`, writes a new private `notes-<UUID>` folder, then atomically publishes the `state.json` index pointing to it. The previous folder and raw index are retained; a failed restore leaves the previous setup untouched.

After restoring, reopen notes in external editors using **Show Markdown file**. An editor still pointing at the old folder is editing a retained backup, and those changes will not sync into the restored setup. Keep the pre-restore backup until you have checked the result.

For unreadable normal state, use the separate flow in [privacy and recovery](privacy.md). Resolve unsaved-change errors before relying on a backup or transfer.

## limits

Only managed note files are live. Exported notes and configs remain copies; full backups are snapshots, not merges. Choosing a different managed folder and automatic cloud or cross-device synchronization are not implemented. External editing support is not a cloud-sync guarantee.
