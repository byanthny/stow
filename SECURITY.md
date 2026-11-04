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
- The app is not sandboxed because it launches `gh`. Bundled accessories are trusted in-process code; the accessory SDK is not a permission boundary.

In scope: anything that lets untrusted input run code, open unexpected programs or URLs, read or write outside Stow's folders, leak private data, or silently lose data. Untrusted input includes GitHub pull request data, files you import or restore (`.stowbackup`, Markdown, theme configs), pasted text, and files changed in the notes folder.

Out of scope: attacks that already require running code as your macOS user, physical access, or a modified build. Report vulnerabilities in `gh`, macOS, or dependencies to their maintainers, and here too if Stow's use of them makes the problem worse.

## Builds

Packages from `./scripts/package.sh` are signed ad hoc for your own Mac. No signed and notarized public builds exist yet, so do not run Stow builds from other people.
