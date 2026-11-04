# Profiles and owner views

Design approved by the owner on 2026-11-03, after a final security, privacy, and cost pass. It replaces the earlier proposal. It is implemented and not yet released; the [implementation plan](profiles-plan.md) records the work. Calls made during the design, rather than by the owner, are marked *(call)* so they are easy to revisit.

## Why

- People keep separate setups on one Mac: work and personal, or any other split. Each setup has its own notes, pinned pull requests, layout, theme, and windows.
- One GitHub account usually reaches several organizations. What separates setups is which repository owners they care about, not which account they use.
- Stow keeps using the existing `gh` login. Several GitHub accounts are a later or community addition; see [several GitHub accounts](#several-github-accounts-later).

## Decided with the owner

Settled on 2026-11-03:

- Any number of profiles with any names. Work and Personal are examples, not built in. A profile covers any mix of organizations and personal owners, and an owner can belong to several profiles. No arbitrary limits.
- Every profile uses the account `gh` is signed in as. No per-profile `gh` configuration, account switching, or account picker in this increment.
- Each profile remembers which owners it shows, so switching profiles switches the cards.
- Profiles run side by side in one Stow app. Each profile is a group of windows that can be hidden, shown, closed, and opened on its own. Separate app copies per profile were rejected: they appear as identical Dock, app-switcher, and menu-bar entries, and they would have to coordinate the shared profile list across processes.
- Every layout choice is a setting with a default, not a fixed rule. Nothing turns on unless the user turns it on.
- The owner accepted the calls proposed during the design conversation.
- Later the same day the owner asked for switching that works like browser workspaces. Additions are marked *(owner request)*: a profile icon, keyboard switching, switching that hides the profile you leave unless you turn that off, and no animation that delays a switch.
- The owner then made the board header's icon the profile switcher, made the title the profile's name, and added **Show board title** to the board layout. These are also marked *(owner request)*.

## Goals

- Isolate each profile's notes, pins, dismissals, cached pull requests and details, expected GitHub login, window placement, theme, board layout, collapsed sections, owner selection, and accessories.
- Keep one writer per profile across processes, using locks the kernel releases on exit or crash.
- Upgrade existing installations in place, without moving or rewriting their files.
- Keep a setup with one profile and cards from one owner looking and behaving exactly as Stow does today. New controls appear only when they have something to do.

## Non-goals

- Several GitHub accounts, `GH_CONFIG_DIR`, `gh auth switch`, or any token handling.
- Moving or copying notes between profiles. Markdown export and import cover it for now.
- Setup transfer to another Mac, sync, or any hosted service. Another Mac stays independent; a reviewed setup export remains separate later work.
- Named owner selections inside a profile. Profiles are the named selections.
- Notifications or background refresh for hidden or closed profiles.

## Anti-goals

These count as failures even if everything else works:

- A profile showing another profile's notes or cards, or another account's cards under its name.
- A new profile, a restore, or an upgrade turning on GitHub or accessories.
- An upgrade that leaves an older build unable to open the existing data.
- An owner filter that hides incomplete-data or account warnings, or changes readiness.
- Notes disappearing because of an owner filter the user did not ask to apply to notes.

## Profiles

- Each profile has a stable random ID, a name, and a color. Names are one line, not empty after trimming, and unique ignoring case, so menus and window labels stay distinguishable *(call)*. Any color is allowed, and each new profile gets a distinct default *(call)*. The color always appears beside the name and is never the only cue.
- A profile can also have an optional icon: an SF Symbol or a single emoji, chosen in Settings → Profiles *(owner request)*. With no icon, only the color and name show.
- A new profile starts empty: no notes, GitHub off with the usual first-use offer, accessories off, and the default theme and layout *(call)*. Nothing is copied from another profile.
- Profiles are listed in creation order and can be reordered in Settings → Profiles *(call)*.
- There is no limit on the number of profiles. Closed profiles cost nothing; each open profile runs its own refreshes.

## Storage

- The existing data folder, `~/Library/Application Support/Stow/`, stays where it is and becomes the first profile, named "Stow" so a one-profile board still reads "Stow" *(call)*. Its files are not moved, so an older build still opens it, and both builds honor its existing `.stow.lock`.
- Each additional profile lives in `profiles/<profile-id>/` inside the data folder, with the same layout as today: `state.json`, a managed notes folder, `.stow.lock`, and retained backups. Profile IDs are UUIDs. Stow ignores anything in `profiles/` that is not a real folder (not a link) named by a UUID and owned by the current user, and the index never stores a path.
- Each profile folder holds a small identity file with the profile's ID, name, color, and optional icon *(call)*. The name travels with the profile, so a folder put back from the Trash keeps it. A profile without an identity file is called "Stow" in the data folder and "Unnamed profile" elsewhere.
- Stow finds profiles by looking for profile data in the data folder and in `profiles/`. The index never decides which profiles exist *(call)*.
- A small `profiles.json` index in the data folder holds only the profile order, which profiles were open or hidden at quit, the most recently active profile, the profile IDs Stow has already seen, and app-wide display settings. It holds no notes, cards, or account data. Stow creates it only when it first has something to record, such as a second profile *(call)*.
- A profile folder Stow has not seen before, such as one put back from the Trash or copied in, opens the first time with GitHub and accessories off and its saved `gh` location cleared, as after a restore *(call)*. The profile kept in the data folder is exempt, so the upgrade keeps its settings.
- Stow creates a first profile only for a new installation: no index and no profile data anywhere. It never creates empty state where it expected a profile, and never creates a new first profile while any profile data exists.
- The index is written atomically with owner-only permissions, like `state.json`. An unreadable, corrupt, or newer index is preserved and never overwritten. Stow still finds every profile, lists them by name, opens the profile in the data folder (or the first listed profile if there is none), and offers **Reset profile list**, which moves the old index to a backup before writing a new one *(call)*. Until then, profile order and open windows are not saved.
- If two profiles end up with the same name, for example after a Put Back, Stow numbers the later one on screen until it is renamed, without rewriting its files *(call)*.
- New `AppState` fields decode with defaults. An older build ignores them and drops them on its next save. That resets display preferences and also turns off **Keep only selected owners on disk**, a privacy setting: the older build saves every owner's cards, and so does this one until the setting is turned on again.

## One app, several open profiles

- One Stow process opens any number of profiles. A new `.stow-app.lock` in the data folder, held for the process lifetime, decides whether another launch hands over to the running copy, as the state lock does today.
- Opening a profile takes that profile's `.stow.lock`, and closing it releases the lock. Stow checks its own open profiles before locking, because a second lock on the same file fails even within one process.
- If another process holds a profile's lock, such as an older build using the first profile, Stow leaves that profile closed and says it is open in another copy of Stow. Other profiles open normally.
- Each open profile owns its state repository, lock, store, theme, GitHub client and refresh coordinator, accessory host, notes-folder watcher, and timers. Nothing in one profile reads another profile's state.
- The app-wide `ThemeController.shared` is replaced: each window renders with its own profile's theme, passed through the SwiftUI environment *(call)*.
- Windows are keyed by profile ID and note ID. Each profile has its own board and its own Settings window.
- At launch, Stow reopens the profiles that were open at quit, each visible or hidden as it was *(call)*. If none would be visible, it shows the most recently active profile *(call)*. The first launch after the upgrade opens only the first profile.
- Reopening a closed profile restores its board and detached notes as they were *(call)*.
- Quit flushes every open profile independently. If any fail, the existing "Keep open" alert names the profiles that could not save. Choosing **Keep open** leaves every profile writable: a profile that already saved must not silently stop saving afterwards.

## Showing the profile

- With one profile named "Stow", Stow looks exactly as it does today. Profile colors and the detached-note accent appear once a second profile exists, or always if the user turns on Settings → Profiles → **Always show profile name** *(call)*.
- The board header keeps its icon beside the title *(owner request)*. It shows the profile's icon if one is set, otherwise the tray, in the profile's color when colors show. The icon opens the profile menu and switcher: switch to or open other profiles, hide or close this one, **New profile…**, and profile settings.
- The board title is the profile's name, so renaming the profile changes the title *(owner request)*. Settings → Board → **Show board title**, on by default, is part of each profile's board layout. Turning it off hides only the title text; the icon and switcher stay *(owner request)*.
- Detached notes show the profile color as a thin accent and the profile name in the title area *(call)*.
- Window titles include the profile name, such as "Work", "Work note", and "Work settings", so the Window menu, Mission Control, and VoiceOver can tell windows apart.
- The Dock menu lists every profile with its state, switches to the chosen one, and offers **New profile…**. With one profile, the Dock and File menus offer only **New profile…** *(call)*.
- New note, Refresh GitHub, Settings…, and Show board act on the profile of the key window, or the most recently active profile when no Stow window is key. With more than one profile, their menu titles name it, as in "New note in Work" *(call)*.

## Hide, show, and close

- **Hide** a profile orders out its board and detached notes together without minimizing them into the Dock. **Show** restores them with the same frames and window levels. Minimizing a single window works as usual, and the app-wide Hide Stow still hides everything.
- A per-profile setting, off by default, keeps always-on-top notes on screen while their profile is hidden, until the user minimizes or closes them.
- Hidden profiles stop polling GitHub and running accessories, and showing a profile refreshes it *(call)*.
- **Close** a profile flushes it, closes its windows, stops its refreshes, accessories, and watchers, and releases its lock. Its data stays on disk. Closing the last open profile leaves Stow running without windows; clicking the Dock icon reopens the most recently active profile.
- Closing a board window only closes that window, as today.
- Opening a profile that is already open brings its windows forward.

## Switching

All of this section is an *(owner request)*.

- **Switch to** a profile opens it if needed and brings its windows forward. It then hides the profile you switched away from, unless that profile's **Hide when switching away** setting is off. The setting is on by default.
- Keyboard shortcuts work only while Stow is the active app, never as system-wide hotkeys. ⌃⌥1 through ⌃⌥9 switch to the profile in that position of the profile order, and ⌃⌥] and ⌃⌥[ switch to the next and previous profile, wrapping around *(call: keys)*. They appear in a Profiles menu that lists every profile.
- The profile menu, the Dock menu, and the Profiles menu all switch the same way.
- A switch happens at once, with no animation that delays it, and respects Reduce Motion.

## GitHub in each profile

- GitHub is opt-in per profile. A new profile starts with it off and shows the existing "Show your pull requests?" offer. The first profile keeps its current setting through the upgrade.
- Every profile launches a validated `gh` with Stow's environment unchanged, so all profiles use the account `gh` is signed in as. The `gh` location stays a machine-local setting of each profile, as today *(call)*.
- Each profile stores the login it last refreshed as. A profile without a stored login adopts the first login it sees.
- When a refresh answers as a different login, the profile discards the result after the first response, marks its cached cards stale, and shows "GitHub is signed in as X. This profile uses Y." **Use X here** clears this profile's cached pull requests, details, and dismissals, keeps its pins and notes, and refreshes. Until then, refreshes keep checking the login and discard any other account's results, and the profile fetches no details. This replaces v1's automatic adoption for every setup, including one with a single profile.
- Open, visible profiles refresh independently. Profiles on the same account fetch the same data and differ only in pins and filters. Profiles that use the same `gh` location share one GitHub client, so a rate-limit backoff pauses all of them *(call)*. Sharing fetched data across profiles is left to the builder.

## Owners

- An owner is the repository owner in a pull request reference: an organization or a user. Owners compare ignoring case and display as GitHub returns them.
- Each profile saves an owner selection: All owners, the default, or any set of owners. Changes save immediately.
- An owner control in the board header, separate from the profile menu, lists All owners and each known owner with a checkmark and a count of its cards that are not dismissed. Known owners come from cached cards, pins, and the current selection. **Add owner…** accepts a GitHub login for an owner that has no cards yet *(call)*.
- The owner control appears when GitHub is on and the profile's cards come from more than one owner, and whenever a selection other than All owners is active, so a filter never hides cards silently. Settings → Board → **Always show owner control** can make it always visible *(call)*.
- The selection only changes what is visible. Refresh, dismissals, and pins are unaffected, and classification is identical in every view. GitHub warnings, incomplete-data messages, and account mismatches always show.
- A per-profile setting, off by default, keeps only the selected owners' pull requests on disk, plus pins *(call)*. With it on, the profile's files and backups leave out other owners' cards, the owner control shows counts for other owners only from the latest refresh, and adding an owner refreshes at once.
- Pinned cards stay visible whatever the selection, because pinning is an explicit choice made in that profile *(call)*.
- An owner that disappears, for example after an organization rename, stays in the selection with a count of zero until the user removes it.
- Board layout gains **Group by owner**, off by default, and **Owner order**, A to Z by default or most cards first. With grouping on, each pull-request section shows owner subheadings with counts. Cards keep their existing order within each owner, and Show more still counts cards per section *(call)*.

## Notes and owner filters

- By default the owner selection never hides notes. Notes linked to a pull request keep showing the owner/repository link they show today.
- A per-profile setting, off by default, hides board notes linked to pull requests from owners outside the selection. Standalone notes always show, detached note windows stay open, and the Notes header says how many notes are hidden *(call)*.

## Backups and data actions

- Save backup, restore, Markdown import and export, Show data folder, and Open notes folder act on the profile whose Settings window is used. Restore replaces only that profile; other profiles and the index are untouched.
- A backup contains one profile's `AppState`, as today, and never the profile list, names, or colors. Restore keeps this profile's machine-local GitHub settings and turns accessories off, as today. A restored login that differs from the `gh` login triggers the mismatch flow instead of silent adoption.
- New per-profile preferences, such as the owner selection, grouping, order, the storage setting, and the hide and notes settings, travel in backups like `boardLayout`.

## Deleting a profile

- Settings → Profiles → **Delete profile…** closes the profile if needed, asks for confirmation naming it, and moves its folder to the Trash so it remains recoverable. Stow never deletes profile data outright.
- The profile kept in the data folder is first moved into `profiles/<its-id>/`, undoing the move if any step fails, and then trashed, so Finder's Put Back returns it to a place Stow looks *(call)*. Stow records the move so a move interrupted by a crash is finished or undone at the next launch. An older build then starts with empty data, which this design accepts; anything it writes there shows up in Stow as another profile.
- Stow refuses while another process holds the profile's lock. The last remaining profile cannot be deleted *(call)*.

## Security, privacy, and cost

- Profiles organize work; they are not a security boundary. Every profile lives in the same macOS account, and anything with access to that account can read every profile's files.
- Identity files and the index are untrusted input, because folders can be copied in. Both have size limits. IDs must be UUIDs, and an identity file's ID must match its folder. Colors must be valid. Names lose control and bidirectional-override characters, so one profile cannot impersonate another in window titles. An icon must be a valid SF Symbol name or a single emoji, otherwise it is dropped without rejecting the profile.
- `.stow-app.lock` and every profile lock follow `StateLock`'s rules: links are never followed, permissions are owner-only, and launched processes do not inherit the lock.
- No URL scheme or other inter-process interface is added. Profile requests from the Dock menu stay inside the running process.
- A profile's backup includes cached cards from every owner its account can see, unless it keeps only its selected owners on disk. Restoring a Work backup on another Mac can otherwise carry personal pull-request titles there.
- Deleted profiles remain readable in the Trash until it is emptied. Profile names appear in window titles, which apps with screen-recording or accessibility access can read.
- Cost stays bounded: hidden and closed profiles do not poll, a mismatched account stops after one response, profiles that use the same `gh` location share rate-limit backoff, and the index is written only when something changes. The builder may defer loading a hidden profile until it is first shown.

## Several GitHub accounts (later)

A read-only spike on 2026-11-03 used `gh` 2.96.0 with temporary config folders and a synthetic account name. It did not log in, switch accounts, or read tokens, and it left the real configuration and keychain unchanged.

| config folder | `gh auth status` reports | `gh api` acts as |
| --- | --- | --- |
| empty | not logged in | nobody; asks for `gh auth login` |
| names the signed-in account | that account | that account |
| names an account with no keychain entry | that account | the globally active account |

- Every config folder shares the macOS keychain. In `gh` 2.96 a folder uses the keychain entry for its own active user and silently falls back to the shared active token when that entry is missing. `gh auth status` labels accounts from the folder's config, so it can be wrong.
- `gh auth login`, `switch`, and `logout` rewrite the shared active token whichever folder they run in. A config folder without the current config version makes `gh` copy the shared token into a new keychain entry on its next run.
- Only the viewer login returned by the API is trustworthy, which is why every refresh verifies it.
- A later design could let a profile name a `gh` config folder the user prepared with ordinary `gh` commands. Stow would pass `GH_CONFIG_DIR`, remove token variables from the child environment, never write `gh` configuration, and keep the viewer check as the guard.
- Two real accounts were not tested, because only one is signed in on the test Mac. Behavior with two accounts comes from reading the `gh` 2.96.0 source.

## Delivery order

1. Profile index, per-profile folders and locks, the instance lock, and the upgrade path, with no visible change for one profile.
2. Profile sessions: per-profile themes, windows keyed by profile, hide, show, close, and open, menus, the Dock menu, per-profile Settings, and profile management.
3. GitHub per profile: per-profile opt-in and the account-mismatch flow.
4. Owners: the selection, the owner control, grouping and order, and the notes setting.
5. Documentation and verification updates.

Each step leaves the app working and ships on its own. The [implementation plan](profiles-plan.md) breaks the steps into tasks.

## Acceptance

- Synthetic tests cover the index (absent, created, corrupt, newer, reset), profile discovery (a put-back folder, a vanished folder, a duplicate name, a link or foreign-owned folder ignored, a hostile name sanitized, a profile not seen before opening with GitHub and accessories off and no `gh` location), isolation of two profiles' notes, cards, themes, and layouts, one lock per profile, a second process, a killed writer releasing its lock, rapid hide, show, close, and open, quit with several profiles where one cannot save, owner filters preserving classification and warnings, keeping only selected owners on disk, the account-mismatch flow, a shared rate-limit backoff, the upgrade from today's data, an older build opening the first profile, and deletion to the Trash, including an interrupted move of the first profile.
- Manual checks in [verification](verification.md) cover several profiles on screen, hide and show with always-on-top notes, switching with the keyboard and with the setting on and off, the Dock and Window menus, VoiceOver labels, and window restoration. Record observed results; automated tests do not prove the user flow.

## Left to the builder

Exact layout, copy, icons, shortcuts, and colors; how the theme reaches views; index field names within these rules; whether profiles share a fetch or rate-limit backoff; how Settings is composed; and any further calls that do not change what this document promises. Mark new calls in the pull request.
