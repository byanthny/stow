# privacy and recovery

## local data

Stow stores its state in `~/Library/Application Support/Stow/state.json`. Settings → **Show data folder** reveals it. This file contains note Markdown, note-to-PR links, cached pull-request metadata and expanded details, pins, dismissals, the last connected login, settings, window positions, and accessory configurations. Private repository titles, comments, branch names, and other private metadata can therefore remain on disk after a refresh.

There is no analytics, telemetry, cloud sync, or Stow account. Notes are not sent to GitHub. Markdown preview uses image placeholders without fetching remote images. GitHub requests run only through the existing GitHub CLI login when the integration is enabled. Opening a link launches the system browser. Stow currently supports `github.com` only.

The state file is plain JSON, not application-encrypted. New storage directories use owner-only permissions, and state replacements are created owner-readable and owner-writable before receiving bytes. Existing directory permissions are preserved. System backups, other software with access to the account, or trusted accessories may still access local data.

Turning off GitHub hides cards and stops new GitHub refreshes. It does not erase the stored cache. Changing accounts clears the previous account’s pull-request cache after a successful refresh; personal notes remain. Do not share the state file when reporting a problem.

## credentials and trusted code

Authenticate with `gh` outside Stow. Stow invokes the CLI directly, does not extract credentials, and does not persist a token. Process response bodies and stderr are not logged. Avoid adding logging of API payloads or environment variables.

The app is not sandboxed because it launches the external CLI. Bundled accessories run in-process as trusted code. The SDK’s narrow data contract is not a permission boundary. See [provider trust](providers.md#portability-and-trust).

## backup and recovery

Quit Stow before manually copying or restoring the state file. Treat every copy and recovery backup as private. For a manual restore, preserve the existing file separately before placing a known-good copy in the data folder, then relaunch.

If saved state is corrupt, unreadable, or from an unsupported schema, Stow blocks replacement writes and preserves the original. Use the app’s explicit recovery action only when ready to start replacement state. Recovery moves the original beside it as `state.json.backup-<unique-id>` before allowing a new state file. It does not repair or import that backup. A failed backup leaves the original unchanged.

If saving fails, keep Stow open to retain edits in memory and check disk space and folder access. On quit, choose **Keep open** unless you intend to discard unsaved changes. Do not delete the data folder as a routine troubleshooting step.

## repository hygiene

Use synthetic fixtures and demo content. Keep real notes, API responses, screenshots of private work, internal domains, network addresses, credentials, machine paths, logs, and local state out of commits and CI uploads. CI scans the full fetched history and working tree with redacted Gitleaks output. A clean scan complements review; it does not prove that every file is safe to publish.
