# profiles and organization views

Proposal only. Queue this after v1 acceptance and before public release. No implementation or account changes are authorized by this plan.

## purpose

- Keep work and personal setups separate while allowing different organization views inside each setup.
- Support several profiles on one Mac first. Treat another computer as an independent installation until an explicit transfer or sync design is approved.
- Keep profile identity, GitHub account context, and repository-owner grouping distinct; an organization is not an authentication account.

## profile boundary

- Give each profile a stable opaque ID and an explicit visible name, such as Work or Personal.
- Separate notes, pins, cached pull requests and details, dismissals, GitHub expectations, window restoration, theme, collapsed sections, and module instances/configuration by profile.
- Scope theme controllers and GitHub clients to the profile/window context; the v1 application-wide theme controller must not bleed appearance across profiles.
- Key open windows by profile ID and note ID. Show the profile name on the board, detached notes, Settings, and profile-switch controls so editing context is clear.
- Keep the profile index small: IDs, names, and launch selection. Store private profile state separately; do not copy another profile's cache when creating one.
- Default a new profile to empty state. Offer explicit duplication of reviewed safe settings later; never silently duplicate notes or account data.

## organization grouping

- Group and filter pull requests by repository owner, covering both organizations and personal owners.
- Offer an All owners view and named owner selections within the current profile. Keep owner controls separate from profile switching.
- Sort owner names consistently and show counts; preserve the existing pull-request ordering within each attention group unless the user chooses another sort.
- Preserve Needs you and Waiting classification inside each owner view. Grouping must not change readiness rules or hide incomplete-data warnings.
- Keep pins associated with their profile and repository. Filtering changes visibility, not refresh truth, dismissal state, or ownership.
- Decide how owner filters affect associated notes before implementation. Default to keeping standalone notes visible and labeling linked notes rather than making notes disappear unexpectedly.

## one mac, several profiles

- Prefer one app process that owns several isolated profile stores and routes new-window/profile requests to that process.
- Enforce one writer per profile across processes. A second launch of the same profile should activate its existing windows or refuse a competing writable session.
- Use an operating-system lock for the profile's writable session, with tested crash recovery. Atomic file replacement alone does not prevent competing writers.
- Restore only the selected profile's windows unless the user explicitly opens another profile. Save and flush each store independently.
- Test concurrent profile windows, rapid switching, quit flushes, duplicate launches, and a crashed writer without touching ordinary user state.

## github account context

- Persist each profile's expected GitHub viewer and verify the actual authenticated viewer on every refresh before accepting results.
- Keep account mismatch, unavailable authentication, and changed-account recovery explicit. Never relabel a profile's cached private cards as another account's data.
- Do not use global `gh auth switch` to implement profile switching; another profile or terminal may be using that CLI context.
- Investigate whether a per-profile `GH_CONFIG_DIR` can use an existing, separately authenticated CLI configuration safely. Validate process environment, discovery, and actual viewer behavior before choosing it.
- Authenticate through normal `gh` flows outside Stow. Do not extract, copy, export, or store tokens. Account selection is an unresolved design task, not an implemented capability.

## another computer

- Default to independent private state on each Mac, even when profile names match. No automatic note or cache sharing is implied.
- Plan a small, versioned configuration export/import for reviewed safe settings. Importing a setup should create a new local profile identity unless a later explicit migration design says otherwise.
- Exclude notes, pins, cached PRs, dismissals, credentials, authentication configuration, and machine-specific paths from configuration export. Allowlist module settings; do not export arbitrary provider configuration.
- Show the included fields before export because profile labels and owner filters can reveal work context. Make organization selections optional to share.
- Treat full-state backup/restore and cross-device note sync as separate features. Any future sync needs an explicit conflict, privacy, account, and recovery design; this proposal promises no hosted backend.

## delivery order and acceptance

- First settle profile identity, visible context, persistence isolation, and the single-writer rule with synthetic tests.
- Then add profile selection and owner grouping without weakening attention classification or notes-only use.
- Resolve and test per-profile GitHub account context before claiming simultaneous work/personal account support.
- Finally add reviewed configuration transfer. Keep note sync, cloud services, and unattended account changes out of this increment.
- Accept only after isolation, wrong-account handling, duplicate launch, crash recovery, and independent-machine behavior are documented with observed results.
