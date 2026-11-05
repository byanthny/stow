# Security policy

## Reporting a vulnerability

Report suspected vulnerabilities privately with **Report a vulnerability** on this repository's Security tab. Do not open a public issue or pull request for them.

Include the Stow commit or version, your macOS version and hardware, steps to reproduce with synthetic data, and the impact you observed. Never attach real notes, `state.json`, `.stowbackup` files, cached pull requests, logs, or credentials.

Stow has one maintainer, so reports are handled on a best-effort basis. There is no bug bounty.

## Supported versions

Stow is pre-1.0. Security fixes land on `main`, and on the latest release once releases exist.

## Scope and trust model

Stow is a local app. It has no server, account system, analytics, or token store.

- Notes, the metadata index, cached pull requests, and backups are plaintext files readable by your macOS user. See [privacy and recovery](docs/privacy.md).
- GitHub access is opt-in and reuses your local GitHub CLI login. Stow launches `gh` directly and never reads, stores, or logs its token.
- The update check is opt-in too. It sends one unauthenticated HTTPS request for this repository's releases, without cookies, credentials, or `gh`, and GitHub sees your IP address. Stow reads at most 1 MiB of the reply, offers only versions newer than the one running, and links only to the offered release's own page under `https://github.com/byanthny/stow/releases/tag/`. It never downloads or installs anything. See [privacy](docs/privacy.md#update-check).
- The app is not sandboxed because it launches `gh`. Bundled accessories are trusted in-process code; the accessory SDK is not a permission boundary.
- Stow runs the chosen `gh` executable as you. It refuses a `gh` that group or other users can write to, but whoever can change that executable or its folders can still run code as you: for example, another administrator who owns Homebrew on a shared Mac.

In scope: anything that lets untrusted input run code, open unexpected programs or URLs, read or write outside Stow's folders, leak private data, or silently lose data. Untrusted input includes GitHub pull request data, the release list the update check reads, files you import or restore (`.stowbackup`, Markdown, theme configs), pasted text, files changed in the notes folder, and profile data that can be copied in: profile folders, their `identity.json` files, and the `profiles.json` index.

Out of scope: attacks that already require running code as your macOS user, physical access, or a modified build. Report vulnerabilities in `gh`, macOS, or dependencies to their maintainers, and here too if Stow's use of them makes the problem worse.

## Builds

Release DMGs are unsigned while Stow is in alpha. GitHub Actions builds each one from its release tag and attaches its SHA-256 and a build provenance attestation; check one with `gh attestation verify Stow-<version>.dmg --repo byanthny/stow`. Use builds only from this repository's Releases. Packages from `./scripts/package.sh` are signed ad hoc for your own Mac, so don't share them, and don't run Stow builds from anywhere else.
