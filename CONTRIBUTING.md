# Contributing

Stow is a small native macOS app with one maintainer. Focused changes with tests are the easiest to review.

## Setup

Use Xcode 16.4 or later with its command line tools selected, then run from the repository root:

```sh
./scripts/test.sh
./scripts/build.sh Debug
./scripts/build.sh Release
```

XcodeGen is only needed when changing targets or dependencies in `project.yml`; keep the checked-in Xcode project in sync. Generate it from a checkout folder named `stow`, because the local package reference takes its name from the folder.

## Run with synthetic data

Debug builds accept `--stow-testing-state <absolute folder> --stow-demo`. Stow then keeps its data in that folder instead of your own, fills a folder without notes with synthetic notes and pull requests, and doesn't refresh from GitHub. Use a new or disposable folder. Without an absolute path, or with the normal data folder, Stow quits rather than touch your own notes.

In Xcode, choose **Product → Scheme → Edit Scheme…**, then **Run → Arguments**, and add these two entries to **Arguments Passed On Launch**. Xcode saves them in the shared scheme, so don't commit that change.

```text
--stow-testing-state /tmp/stow-demo
--stow-demo
```

From Terminal, build the Debug app and open a new copy with the same arguments:

```sh
./scripts/build.sh Debug
open -n build/DerivedData/Debug/Build/Products/Debug/Stow.app --args --stow-testing-state /tmp/stow-demo --stow-demo
```

Remove the folder to start over. Screenshots for issues and pull requests should come from this synthetic state.

## Changes

- Read [AGENTS.md](AGENTS.md) for the project's invariants. Notes are canonical `<UUID>.md` files. GitHub readiness stays conservative. Stow never reads the `gh` token. Accessories are trusted code.
- Use conventional commit subjects, such as `feat(notes): restore detached windows` or `fix: keep cached cards on partial refresh`.
- Add or update tests. For UI, persistence, or platform changes, also run the relevant checks in [verification](docs/verification.md) and say which macOS version and hardware you used.
- For UI changes, and before a release, run `./scripts/accessibility.sh` locally. CI doesn't run it. It audits the Debug app through UI automation, needs Automation Mode approval, and moves the pointer while it runs.
- Use synthetic data only. Do not commit real notes, pull request data, logs, local state, credentials, machine paths, or internal hosts, and keep them out of issues and screenshots too.
- Report security problems privately; see [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the project's GNU General Public License v3.0 or later. See [LICENSE](LICENSE).
