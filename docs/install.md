# local installation

Build with `./scripts/package.sh`, unzip `build/Stow.zip`, and move `Stow.app` to Applications. Open it from Finder. The package is signed ad hoc for local development; Developer ID signing and notarization are not configured. If macOS asks for confirmation, use its Open action for your own local build.

Stow appears in the Dock. Command-N creates a note; Command-0 reopens the board. Closing the board leaves detached notes open. Closing a detached note returns it to the board. Delete is a separate note action that also removes the managed Markdown file.

GitHub is optional. Install and authenticate GitHub CLI separately with `gh auth login --hostname github.com`. In Stow Settings, enable pull requests or choose the installed `gh` executable if discovery fails. Disabling GitHub leaves notes usable.

## move or back up a setup

Use Settings → **Save backup…** to create a private `.stowbackup` containing notes and the full setup. On the destination Mac, use **Restore backup…**, inspect the preview, and confirm replacement. Stow keeps a pre-restore backup. GitHub CLI authentication must be set up independently.

For a manual copy, quit Stow and back up the entire `~/Library/Application Support/Stow/` folder. Keep the index, its referenced notes folder, and retained backups together. Copying `state.json` alone does not preserve notes. Keep backups outside the repository and treat them as private plaintext.

Use **Open notes folder** or a note's **Show Markdown file** action to find current live Markdown files; restored setups may use a different versioned folder. Reopen files in external editors after restore. For independent portable copies, export notes as `.md` and appearance as `.conf`. See [notes, configs, and backups](portability.md) and [privacy and recovery](privacy.md).

For source changes, pull the repository, open `Stow.xcodeproj`, and run the Stow scheme. Read [appearance](appearance.md), [accessory providers](providers.md), and [verification](verification.md) for customization and checks.
