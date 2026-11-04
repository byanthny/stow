# Stow

A small native macOS board for Markdown notes and GitHub pull requests.

**Alpha.** Download the unsigned DMG from [Releases](https://github.com/byanthny/stow/releases), or build it yourself. Expect rough edges, keep backups of notes you care about, and [report bugs](#reporting-bugs) with the issue forms.

Keep notes on the board or detach them into separate windows. Each detached note has its own always-on-top setting. Closing a note window keeps the note; deleting it is explicit. The board groups pull requests into “Needs you” and “Waiting” using observed GitHub state, and keeps cached cards when a refresh is incomplete.

Keep separate setups as profiles, such as work and personal. Each has its own notes, pull requests, layout, and theme, and profiles can be hidden, shown, and switched from the keyboard. Filter the board by repository owner, or group pull requests by owner.

GitHub is optional and stays off until you turn it on. Notes work without `gh`, an account, or a network connection. Accessories are optional too: the bundled `org.stow.sample` provider is disabled by default.

Checking for updates is off until you turn it on in Settings → **Updates**. Stow then asks GitHub once a day whether a newer version is out, and the board links to its release page; nothing is downloaded. **Check for updates…** in the Stow menu asks once, any time. The request sends no account or cookies, and GitHub sees your IP address; see [privacy](docs/privacy.md#update-check).

<img src="docs/images/board.png" width="360" alt="Stow board with pull requests and notes">

## Requirements

- **Running:** macOS 14 or later. Hands-on testing so far covers macOS 26 on Apple silicon, and automated smoke checks pass on Intel with macOS 15. Stow is untested on macOS 14; see [verification](docs/verification.md).
- **Building:** Xcode 16.4 or later. Xcode 16.4 needs macOS 15.3 or later, so Stow can't be built on macOS 14.
- **Pull requests (optional):** [GitHub CLI](https://cli.github.com/), signed in to `github.com`.

## Appearance

Choose a light or dark preset, adjust colors and background opacity, and set separate interface and note fonts, sizes, and note line height. Changes apply to the board and open notes. Copy, paste, edit, or share a short plaintext theme config. Import and export use `.conf`; existing JSON themes remain readable. See [appearance and themes](docs/appearance.md).

```ini
preset = graphite
font-family = Menlo
font-size = 14
background-opacity = 0.85
```

<img src="docs/images/appearance.png" width="440" alt="Stow appearance settings">

## Build

Use Xcode 16.4 or later with its command line tools selected. Open the checked-in project:

```sh
open Stow.xcodeproj
```

Choose the **Stow** scheme and run. Xcode downloads the pinned MarkdownUI dependency on the first build. XcodeGen is only needed when changing `project.yml`; project generation is not a setup prerequisite.

From the repository root:

```sh
./scripts/test.sh
./scripts/build.sh Debug
./scripts/package.sh
```

The scripts put their output in `build/`. Pass another directory as the second build argument or the first test/package argument, for example `./scripts/package.sh build/local`. Packaging builds a universal Release app for Apple silicon and Intel, signs it ad hoc for local use, and writes `Stow.zip` and its SHA256 checksum. This is a development package; Developer ID distribution and notarization are not configured.

## Use

For a local package, unzip `Stow.zip` and move `Stow.app` to Applications. See [installation](docs/install.md).

- Create a note with **Command-N**. Switch between editing and Markdown preview from the note controls.
- Keep code snippets in notes. Inline code and fenced code blocks are styled as code while you type and in the preview.
- Paste a canonical `https://github.com/example/project/pull/42` URL outside the editor to pin a pull request. Text following one URL becomes an attached note. Other or ambiguous text stays intact as a note.
- Use the header pin to keep the board on top or let it sit behind other windows. Detached notes keep their own pin settings.
- Detach a note into its own window with the arrow button in its header. Use **Command-0** or the Dock icon to reopen the board.
- The board shows **Needs you**, **Notes**, then **Waiting**. Section titles stay visible while you scroll, and each pull request section shows three cards before **Show more**. Click **Needs you** or **Waiting** to collapse it; Stow remembers the choice. Notes show as one-line rows: click one to open it, opening another closes it, and the pop-out button gives a note its own window. Change the order, the card count, how notes open, and whether the header shows the title in Settings → **Board**.
- On first launch, Stow asks before using GitHub; change it later in Settings. Install [GitHub CLI](https://cli.github.com/) and authenticate outside Stow with `gh auth login --hostname github.com`. Stow uses that existing login; it does not extract or save a token. Use **Choose gh…** if automatic discovery fails.
- Click a pull request to load details. Stow reads GitHub state; it does not merge, review, or modify pull requests.

## Notes and Backups

Stow keeps its data in `~/Library/Application Support/Stow/`. That folder holds the first profile, and other profiles live in `profiles/<UUID>/` inside it. See [privacy and recovery](docs/privacy.md#local-data) for what each file holds.

Notes are live UTF-8 Markdown files in each profile's managed folder. Use **Open notes folder** in Settings or **Show Markdown file** on a note to edit them in another app. Stow reloads external changes and preserves both versions when it detects conflicting edits. Keep managed UUID filenames unchanged.

Import or export ordinary `.md` copies, or use **Save backup…** for a profile's notes and full setup. Backups are per profile: each holds one profile and never the profile list, and restoring one replaces only that profile. Restore validates the backup and keeps the previous files before replacing the setup. Full backups contain private note and cached PR data; theme configs share appearance separately. See [notes, configs, and backups](docs/portability.md).

## Reporting Bugs

Open an issue with the [bug report form](https://github.com/byanthny/stow/issues/new?template=bug.yml). It asks for the Stow version or commit, your macOS version and Mac, whether GitHub is on, and steps to reproduce. Use synthetic data: never paste private notes, pull request data, or tokens. Suggest a change with the [feature request form](https://github.com/byanthny/stow/issues/new?template=feature.yml).

Report vulnerabilities privately as described in the [security policy](SECURITY.md), not in an issue.

## Development

The Swift package tests the core, GitHub transport, and accessory contract independently of the app. `scripts/test.sh` also runs the hosted app tests using local ad-hoc signing and an isolated test host. `scripts/accessibility.sh` runs Xcode's accessibility audit against the Debug app through UI automation. The app uses AppKit windows, SwiftUI views, and a native text editor.

Read [architecture](docs/architecture.md), [appearance](docs/appearance.md), [accessory providers](docs/providers.md), [privacy and recovery](docs/privacy.md), and the [verification checklist](docs/verification.md). Feature acceptance, macOS 14 behavior, and performance claims require recorded validation; see that checklist for current evidence.

See the [roadmap](docs/roadmap.md) for the ordered release, public-site, and extension queue.

## Contributing

See [contributing](CONTRIBUTING.md).

## License

Stow is free software under the [GNU General Public License v3.0 or later](LICENSE). Third-party dependencies keep their own licenses; [their notices](App/ThirdPartyNotices.txt) ship in the app bundle.
