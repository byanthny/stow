# contributing

Stow is a small native macOS app with one maintainer. Focused changes with tests are the easiest to review.

## setup

Use Xcode 16.4 or later with its command line tools selected, then run from the repository root:

```sh
./scripts/test.sh
./scripts/build.sh Debug
./scripts/build.sh Release
```

XcodeGen is only needed when changing targets or dependencies in `project.yml`; keep the checked-in Xcode project in sync. Debug builds accept `--stow-testing-state <absolute folder> --stow-demo` to run against synthetic state instead of your own notes.

## changes

- Read [AGENTS.md](AGENTS.md) for the project's invariants. Notes are canonical `<UUID>.md` files. GitHub readiness stays conservative. Stow never reads the `gh` token. Accessories are trusted code.
- Use conventional commit subjects, such as `feat(notes): restore detached windows` or `fix: keep cached cards on partial refresh`.
- Add or update tests. For UI, persistence, or platform changes, also run the relevant checks in [verification](docs/verification.md) and say which macOS version and hardware you used.
- Use synthetic data only. Do not commit real notes, pull request data, logs, local state, credentials, machine paths, or internal hosts, and keep them out of issues and screenshots too.
- Report security problems privately; see [SECURITY.md](SECURITY.md).

## license

By contributing, you agree that your contributions are licensed under the project's GNU General Public License v3.0 or later. See [LICENSE](LICENSE).
