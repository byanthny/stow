# local installation

Build with `./scripts/package.sh`, unzip `build/Stow.zip`, and move `Stow.app` to Applications. Open it from Finder. The package is signed ad hoc for local development; Developer ID signing and notarization are not configured. If macOS asks for confirmation, use its Open action for your own local build.

Stow appears in the Dock. Command-N creates a note; Command-0 reopens the board. Closing the board leaves detached notes open. Closing a detached note returns it to the board. Delete is a separate note action.

GitHub is optional. Install and authenticate GitHub CLI separately with `gh auth login --hostname github.com`. In Stow Settings, enable pull requests or choose the installed `gh` executable if discovery fails. Disabling GitHub leaves notes usable.

Local state is `~/Library/Application Support/Stow/state.json`. Back up that folder before moving machines. Do not copy it into the repository. See [privacy and recovery](privacy.md) for failed or unsupported-state recovery.

For source changes, pull the repository, open `Stow.xcodeproj`, and run the Stow scheme. Read [appearance](appearance.md), [accessory providers](providers.md), and [verification](verification.md) for customization and checks.
