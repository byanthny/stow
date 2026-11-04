# Local installation

Build with `./scripts/package.sh`, unzip `build/Stow.zip`, and move `Stow.app` to Applications. Open it from Finder. The package is signed ad hoc for local development; Developer ID signing and notarization are not configured. If macOS asks for confirmation, use its Open action for your own local build. Do not share ad-hoc builds or open ones built by someone else.

Stow appears in the Dock. Command-N creates a note; Command-0 reopens the board. Closing the board leaves detached notes open. Closing a detached note returns it to the board. Delete is a separate note action that also removes the managed Markdown file.

GitHub is optional and off until you choose it. Install and authenticate GitHub CLI separately with `gh auth login --hostname github.com`, then choose **Use GitHub** on the board's first-launch prompt or enable pull requests in Settings. Choose the installed `gh` executable there if discovery fails. Disabling GitHub leaves notes usable.

Stow starts with one profile. To keep separate setups, such as work and personal, choose **New profile…** from the File menu, the Dock menu, the board's profile menu, or Settings → **Profiles**. Each profile has its own notes, pull requests, layout, and theme, and a new one starts with GitHub off. See [privacy and recovery](privacy.md#profiles) for where profiles are kept.

## Move or back up a setup

Backups are per profile. In a profile's Settings, use **Save backup…** to create a private `.stowbackup` containing that profile's notes and full setup, and repeat for each profile you want to move. On the destination Mac, use **Restore backup…** in the profile it should replace, inspect the preview, and confirm replacement. Restoring replaces only that profile, and Stow keeps a pre-restore backup. GitHub CLI authentication and Stow's GitHub settings stay with each Mac.

For a manual copy, quit Stow and back up the entire `~/Library/Application Support/Stow/` folder. It holds every profile: the first profile's files, and the others in `profiles/<UUID>/`. Keep the index, its referenced notes folder, and retained backups together. Copying `state.json` alone does not preserve notes. Keep backups outside the repository and treat them as private plaintext.

Use **Open notes folder** or a note's **Show Markdown file** action to find current live Markdown files; restored setups may use a different versioned folder. Reopen files in external editors after restore. For independent portable copies, export notes as `.md` and appearance as `.conf`. See [notes, configs, and backups](portability.md) and [privacy and recovery](privacy.md).

For source changes, pull the repository, open `Stow.xcodeproj`, and run the Stow scheme. Read [appearance](appearance.md), [accessory providers](providers.md), and [verification](verification.md) for customization and checks.
