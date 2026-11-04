# Profiles implementation plan

> For agents: execute this plan task by task with superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkboxes (`- [ ]`) for tracking.

**Goal:** Ship the approved [profiles and owner views design](profiles.md): several isolated profiles open side by side in one Stow app, per-profile owner selection and grouping, and a paused profile instead of silent account adoption.

**Architecture:** `StowCore` gains profile discovery, an index, deletion to the Trash, and pure owner rules, all testable without the app. The app splits today's single `AppStore`/window set into one `ProfileSession` per open profile, coordinated by a `ProfileManager`; each session keeps its own repository, lock, store, theme, and windows. `GHClient` stops after the first response when the account differs, and profiles that use the same `gh` location share one client.

**Tech stack:** Swift 6, macOS 14+, AppKit and SwiftUI, XCTest (core and hosted app tests) and Swift Testing (GitHub tests). No new dependencies.

**Spec:** [profiles.md](profiles.md). Read it before starting any task; this plan argues from it.

## Global constraints

- Target macOS 14 and Swift 6. Add no dependencies. Keep `Package.resolved` unchanged.
- "Every layout choice is a setting with a default, not a fixed rule. Nothing turns on unless the user turns it on."
- "Keep a setup with one profile and cards from one owner looking and behaving exactly as Stow does today."
- The first profile stays in the data folder and is named "Stow" (task 9 renames the earlier "Main" fallback). Other profiles live in `profiles/<profile-id>/`. The identity file is `identity.json`, the index is `profiles.json`, and the instance lock is `.stow-app.lock`.
- Hold a profile's `.stow.lock` before writing its folder. Hold `.stow-app.lock` for the process lifetime.
- Launch only `gh` paths `GHClient.isUsableExecutable` accepts, with Stow's environment unchanged. Never read tokens or set `GH_CONFIG_DIR`. Add no URL scheme or other inter-process interface.
- New profiles start with GitHub off and the existing offer. Profiles not seen before start with GitHub and accessories off and no saved `gh` location. Restores keep each profile's machine-local GitHub settings.
- Tests use synthetic data in temporary folders. They never touch `~/Library/Application Support/Stow/` or the user's Trash; inject the trash operation.
- New app files go into the checked-in project with XcodeGen 2.45.4 (`xcodegen generate`). XcodeGen names the local package reference after the checkout folder, so restore the name `stow`; the project diff must contain only the new files.
- Documentation headings use sentence case (capital first word, proper names such as GitHub kept as they are; README stays in title case), with short, direct prose. Commits use conventional subjects and the existing signing setup; never bypass signing.
- Core tests: `swift test --filter <TestClass>`. Hosted tests: the `xcodebuild … test` command from `scripts/test.sh`, with `-only-testing:StowAppTests/<TestClass>` appended. Full check: `./scripts/test.sh`, `./scripts/build.sh Debug`, `./scripts/build.sh Release`.

## Review focus

1. A refresh or save still running when its profile is hidden or closed. It must land only in its own profile, and nothing may be written after the lock is released. Tested in task 9.
2. External edits to a hidden profile's notes. They must be merged when the profile is shown, not lost and not turned into conflict copies. Tested in task 9.
3. Long, emoji, right-to-left, or hostile profile names. They are shortened or cleaned, never rejected outright, and cannot impersonate another profile. Tested in task 2.
4. An index write failing because the disk is full or the folder is read-only. Existing profiles stay listed and usable, and the error is shown. Tested in task 4.
5. Owner names that differ only by case, such as a typed "acme" against GitHub's "Acme". They are one owner everywhere. Tested in task 15.

## File map

| file | responsibility |
| --- | --- |
| `Sources/StowCore/StateLock.swift` | named locks, including the instance lock |
| `Sources/StowCore/Profiles.swift` (new) | `ProfileIdentity`, `ProfileIndex`, `ProfileError`, name and color validation |
| `Sources/StowCore/ProfileCatalog.swift` (new) | discovery, index reads and writes, profile changes, deletion to the Trash |
| `Sources/StowCore/Owners.swift` (new) | owner summaries, visibility, grouping, pruning, note visibility |
| `Sources/StowCore/Models.swift`, `BoardLayout.swift`, `Portability.swift`, `StateRepository.swift` | new per-profile fields, arrival rules, `reopen()` |
| `Sources/StowGitHub/GHClient.swift`, `Transport.swift` | account-mismatch short circuit and error |
| `App/Theme.swift` and the views | per-profile theme through the SwiftUI environment |
| `App/ProfileSession.swift` (new) | one profile's store, lock, and windows |
| `App/ProfileManager.swift` (new) | open profiles, launch and quit, shared GitHub clients |
| `App/ProfilesSettingsView.swift`, `App/OwnerControl.swift` (new) | profile management, owner menu |
| `App/Windows.swift` | `StowPanel`, `AppDelegate` lifecycle, menus, Dock menu |

---

### Task 1: named locks

**Files:** modify `Sources/StowCore/StateLock.swift`; test `Tests/StowCoreTests/StateLockTests.swift`.

**Interfaces:**
- Produces: `StateLock.acquire(named filename: String, in directory: URL) -> StateLock.Outcome`; `StateLock.instanceFilename = ".stow-app.lock"`. The existing `acquire(forStateAt:)` calls it with `StateLock.filename`.

- [ ] **Step 1: Write the failing tests**

```swift
func testNamedLocksAreIndependent() throws {
    guard case .acquired = StateLock.acquire(named: StateLock.instanceFilename, in: folder),
        case .acquired = StateLock.acquire(named: StateLock.filename, in: folder) else { return XCTFail() }
}
func testSecondAcquireInSameProcessIsRefusedUntilRelease() throws {
    guard case .acquired(let lock) = StateLock.acquire(named: "a.lock", in: folder) else { return XCTFail() }
    guard case .heldByAnotherProcess = StateLock.acquire(named: "a.lock", in: folder) else { return XCTFail() }
    lock.release()
    guard case .acquired = StateLock.acquire(named: "a.lock", in: folder) else { return XCTFail() }
}
```

Keep each `.acquired` lock alive until the test ends.

- [ ] **Step 2: Run `swift test --filter StateLockTests`.** Expected: compile failure, `acquire(named:in:)` not found.
- [ ] **Step 3: Move the body of `acquire(forStateAt:)` into `acquire(named:in:)` unchanged**, keeping `O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK`, mode `0o600`, and the regular-file check.
- [ ] **Step 4: Run `swift test --filter StateLockTests`.** Expected: all pass, including the four existing tests.
- [ ] **Step 5: Commit** `feat(core): named state locks`.

### Task 2: profile identity and index values

**Files:** create `Sources/StowCore/Profiles.swift`; test `Tests/StowCoreTests/ProfileTests.swift`.

**Interfaces:**
- Produces:

```swift
public enum ProfileError: Error, Equatable, Sendable {
    case invalidIdentity, invalidIndex, newerIndex(Int), indexNeedsReset
    case emptyName, duplicateName, invalidColor, inUse, lastProfile, notFound, unwritable
}
public struct ProfileIdentity: Codable, Equatable, Sendable {
    public var id: UUID; public var name: String; public var color: String   // "#RRGGBB"
    public static let filename = "identity.json"
    public static let maximumBytes = 16 * 1024
    public static let maximumNameLength = 80                                // characters (grapheme clusters)
    public static func sanitizedName(_ raw: String) -> String?
    public static func isValidColor(_ hex: String) -> Bool
    public static func decode(_ data: Data, folderID: UUID?) throws -> ProfileIdentity   // .invalidIdentity
}
public struct ProfileIndex: Codable, Equatable, Sendable {
    public struct OpenProfile: Codable, Equatable, Sendable { public var id: UUID; public var isHidden: Bool }
    public static let filename = "profiles.json"
    public static let currentVersion = 1
    public static let maximumBytes = 256 * 1024
    public var schemaVersion = currentVersion
    public var order: [UUID] = []
    public var open: [OpenProfile] = []
    public var lastActiveID: UUID?
    public var seenIDs: [UUID] = []
    public var alwaysShowProfileName = false
    public static func decode(_ data: Data) throws -> ProfileIndex   // .invalidIndex or .newerIndex(version)
}
```

- [ ] **Step 1: Write the failing tests**

```swift
func testSanitizedNameRemovesControlAndBidirectionalCharacters() {
    XCTAssertEqual(ProfileIdentity.sanitizedName("Wo\u{202E}rk\n"), "Work")
    XCTAssertEqual(ProfileIdentity.sanitizedName("\u{2066}Acme\u{2069}"), "Acme")
    XCTAssertNil(ProfileIdentity.sanitizedName(" \u{200E} "))
}
func testSanitizedNameKeepsEmojiAndRightToLeftText() {   // review focus 3
    XCTAssertEqual(ProfileIdentity.sanitizedName("👨‍👩‍👧 Family"), "👨‍👩‍👧 Family")
    XCTAssertEqual(ProfileIdentity.sanitizedName("עבודה"), "עבודה")
    XCTAssertEqual(ProfileIdentity.sanitizedName(String(repeating: "a", count: 200))?.count, 80)
}
func testColorValidation() {
    XCTAssertTrue(ProfileIdentity.isValidColor("#1A2B3C"))
    for bad in ["1A2B3C", "#12345", "#GGGGGG", "#1A2B3C4D"] { XCTAssertFalse(ProfileIdentity.isValidColor(bad)) }
}
func testIdentityRejectsMismatchedFolderAndOversizedData() {
    // identity with id A decoded for folder B -> .invalidIdentity
    // maximumBytes + 1 bytes -> .invalidIdentity; invalid color -> .invalidIdentity
}
func testIndexRejectsNewerVersionAndOversizedData() {
    // {"schemaVersion":2,...} -> .newerIndex(2); maximumBytes + 1 bytes -> .invalidIndex
}
```

- [ ] **Step 2: Run `swift test --filter ProfileTests`.** Expected: compile failure.
- [ ] **Step 3: Implement `Profiles.swift`.** `sanitizedName` trims whitespace and newlines; removes Unicode `Cc`, U+2028, U+2029, U+061C, U+200E, U+200F, U+202A–U+202E, and U+2066–U+2069; keeps U+200C and U+200D; truncates to 80 grapheme clusters; and returns nil when empty. Decoders check the byte limit before decoding, and the identity decoder also sanitizes the name.
- [ ] **Step 4: Run `swift test --filter ProfileTests`.** Expected: pass.
- [ ] **Step 5: Commit** `feat(core): profile identity and index values`.

### Task 3: discover profiles

**Files:** create `Sources/StowCore/ProfileCatalog.swift`; test `Tests/StowCoreTests/ProfileCatalogTests.swift`.

**Interfaces:**
- Consumes: task 2 types; `LiveNoteIO.read`, `LiveNoteIO.write`, and `LiveNoteIO.ensureDirectory` for owner-only files.
- Produces:

```swift
public struct ProfileEntry: Equatable, Sendable {
    public var id: UUID; public var folder: URL; public var isDataFolder: Bool
    public var name: String      // sanitized; "Main" or "Unnamed profile" fallback; numbered on screen when duplicated
    public var color: String
    public var isArrival: Bool   // not in seenIDs; always false for the data folder profile
}
public enum ProfileIndexStatus: Equatable, Sendable { case absent, loaded, needsReset }
public struct ProfileCatalogSnapshot: Equatable, Sendable {
    public var profiles: [ProfileEntry]   // index order first, then by name
    public var index: ProfileIndex
    public var indexStatus: ProfileIndexStatus
    public var isNewInstallation: Bool
}
public actor ProfileCatalog {
    public static let profilesDirectoryName = "profiles"
    public init(dataFolder: URL, currentUserID: uid_t = getuid(),
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
    public func load() throws -> ProfileCatalogSnapshot
}
```

- [ ] **Step 1: Write the failing tests:**
  - `testEmptyFolderIsNewInstallation`;
  - `testExistingStateBecomesMainWithoutWritingFiles`: a root `state.json` gives one profile with `isDataFolder`, name "Main", `isArrival == false`, `indexStatus == .absent`, and an unchanged folder listing;
  - `testProfileFoldersAreFoundWithoutIndex`: `profiles/<UUID>/identity.json` named "Work" is listed with `isArrival == true`;
  - `testLinksNonUUIDAndForeignFoldersAreIgnored`: use a symlinked UUID folder, a folder named `notes`, and a catalog built with `currentUserID: getuid() + 1`;
  - `testMismatchedIdentityFallsBackToUnnamed`;
  - `testCorruptOrNewerIndexIsPreservedAndNeedsReset`: index bytes are unchanged after `load()`, and profiles are sorted by name;
  - `testDuplicateNamesAreNumberedOnScreenOnly`: names are "Work" and "Work 2", and both identity files are unchanged;
  - `testSeenProfilesAreNotArrivals`.
- [ ] **Step 2: Run `swift test --filter ProfileCatalogTests`.** Expected: compile failure.
- [ ] **Step 3: Implement `load()`.** The data folder holds a profile when it has `state.json` or `identity.json`. A profile folder counts only when `lstat` reports a directory, the owner is `currentUserID`, the name parses as a UUID, and it contains `state.json` or `identity.json`. The data folder profile takes its ID from a valid identity file, otherwise a fresh in-memory UUID. It is a new installation only when there is no index file and no profile data anywhere. `load()` writes nothing.
- [ ] **Step 4: Run `swift test --filter ProfileCatalogTests`.** Expected: pass.
- [ ] **Step 5: Commit** `feat(core): discover profiles from folders`.

### Task 4: change profiles

**Files:** modify `Sources/StowCore/ProfileCatalog.swift`; test `Tests/StowCoreTests/ProfileCatalogTests.swift`.

**Interfaces:**
- Produces, on `ProfileCatalog`:
  - `createProfile(name: String, color: String) throws -> ProfileEntry`
  - `rename(_ id: UUID, to name: String) throws`
  - `setColor(_ id: UUID, to color: String) throws`
  - `move(_ id: UUID, by offset: Int) throws`
  - `recordSession(open: [ProfileIndex.OpenProfile], lastActiveID: UUID?) throws`
  - `markSeen(_ id: UUID) throws`
  - `setAlwaysShowProfileName(_ value: Bool) throws`
  - `resetIndex() throws -> URL`, which returns the backup of the old index

- [ ] **Step 1: Write the failing tests:**
  - `testCreateWritesFolderIdentityAndIndex`: the folder mode is `0o700`; the identity name is right; `order` and `seenIDs` contain the ID; the data folder's `identity.json` now exists with name "Main".
  - `testEmptyAndDuplicateNamesAreRejected`: "work" against an existing "Work" gives `.duplicateName`; "  " gives `.emptyName`; "#12" gives `.invalidColor`.
  - `testChangesWaitForResetThenSucceed`: with a corrupt index, `rename` throws `.indexNeedsReset`; `resetIndex()` returns a file whose bytes equal the corrupt index; then `rename` succeeds.
  - `testIndexWriteFailureLeavesProfilesUsable` *(review focus 4)*: with the data folder at `0o500`, `createProfile` throws `.unwritable` and `load()` still lists the existing profiles. Restore the mode in `tearDown`.
- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement the changes.** Names pass through `sanitizedName`; uniqueness uses a case-insensitive compare. Every index write is atomic and owner-only. The first index write also writes the data folder profile's identity file, so its ID persists. Writes while `.needsReset` throw, except `resetIndex()`.
- [ ] **Step 4: Run the tests.** Expected: pass.
- [ ] **Step 5: Commit** `feat(core): create, rename, and order profiles`.

### Task 5: delete profiles to the Trash

**Files:** modify `Sources/StowCore/ProfileCatalog.swift`; test `Tests/StowCoreTests/ProfileCatalogTests.swift`.

**Interfaces:**
- Produces: `ProfileCatalog.trash(_ id: UUID) throws`. `load()` also finishes interrupted moves.

- [ ] **Step 1: Write the failing tests**, using a `trash` closure that moves into a temporary folder:
  - `testTrashMovesProfileFolderAndUpdatesIndex`: the ID is gone from `order`, `open`, and `seenIDs`, and `lastActiveID` is cleared if it pointed there.
  - `testFirstProfileMovesIntoProfilesThenTrash`: the fake trash receives `<id>/` with `state.json` and the notes folder; `profiles.json`, `profiles/`, `.stow-app.lock`, and `.stow.lock` stay in the data folder.
  - `testLastProfileCannotBeDeleted`: throws `.lastProfile`.
  - `testLockedProfileIsRefused`: the test holds that folder's `StateLock`, and `trash` throws `.inUse`.
  - `testInterruptedFirstProfileMoveIsFinishedAtLoad`: leave `.moving.json` with half the items moved. `load()` completes the move, lists the profile from `profiles/<id>/`, and trashes nothing.
- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement `trash`.**
  - Hold the profile's lock during the move.
  - For the data folder profile, create `profiles/<id>/` first; fail if it exists.
  - Write `.moving.json` listing the items to move: `state.json`, `identity.json`, `notes`, `notes-<UUID>`, `state.json.*`, `notes.backup-*`, `notes-*.backup-*`, and `pre-restore-*.stowbackup`.
  - Move each item, moving them all back if any move fails.
  - Delete the journal, call `trash`, then update the index.
- [ ] **Step 4: Run the tests.** Expected: pass.
- [ ] **Step 5: Commit** `feat(core): delete profiles to the Trash`.

### Task 6: per-profile fields and arrival rules

**Files:** modify `Sources/StowCore/Models.swift`, `BoardLayout.swift`, `Portability.swift`, and `StateRepository.swift`; tests in `Tests/StowCoreTests/StateCompatibilityTests.swift`, `BoardPreferencesTests.swift`, `PortabilityTests.swift`, and `LiveNotesTests.swift`.

**Interfaces:**
- Produces:

```swift
public struct OwnerSelection: Codable, Equatable, Sendable {
    public var owners: [String]                    // empty means All owners; unique ignoring case, case-insensitive sort, first spelling kept
    public init(_ owners: [String] = [])
    public var isAll: Bool { get }
    public func contains(_ owner: String) -> Bool  // ignores case
    public static func isValidLogin(_ login: String) -> Bool   // ^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$
}
// AppState, decoded with decodeIfPresent and these defaults
public var ownerSelection = OwnerSelection()
public var keepsOnlySelectedOwners = false
public var hideKeepsAlwaysOnTopNotes = false
// BoardLayout, same rule; OwnerOrder is nested in BoardLayout; an unknown ownerOrder decodes as .alphabetical
public enum OwnerOrder: String, Codable, Sendable { case alphabetical, mostCards }
public var groupByOwner = false
public var ownerOrder: OwnerOrder = .alphabetical
public var alwaysShowOwnerControl = false
public var hidesNotesForHiddenOwners = false
extension AppState { public func preparedForArrival() -> AppState }  // GitHub off, gh location nil, every accessory disabled
extension StateRepository { public func reopen() }                   // writable again after saveAndClose
```

- [ ] **Step 1: Write the failing tests:**
  - `testOlderStateDecodesNewFieldsWithDefaults`;
  - `testUnknownOwnerOrderFallsBackToAlphabetical`;
  - `testOwnerSelectionNormalizesAndIgnoresCase`: `["acme", "Acme", "beta"]` gives `["acme", "beta"]`, and `contains("ACME")` is true;
  - `testLoginValidation`: "a" and "acme-labs" are valid; "-acme", "acme-", "a--b", "a_b", and a 40-character login are invalid;
  - `testArrivalTurnsOffGitHubAccessoriesAndGHLocation`;
  - `testBackupCarriesOwnerPreferences`;
  - `testReopenAllowsSavingAfterSaveAndClose`: `saveAndClose(a)`, `reopen()`, `save(b)`, and `load()` returns `b`.
- [ ] **Step 2: Run `swift test --filter StowCoreTests`.** Expected: the new tests fail.
- [ ] **Step 3: Implement the fields, `preparedForArrival()`, and `reopen()`**, which sets `isClosed = false`. Board Settings → Reset keeps resetting every `BoardLayout` field.
- [ ] **Step 4: Run `swift test --filter StowCoreTests`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): per-profile owner and window preferences`.

### Task 7: a theme per store

**Files:** modify `App/Theme.swift`, `App/AppStore.swift`, `App/Windows.swift`, and every view that uses `Color.stow…`, `Font.stow(…)`, or `ThemeController.shared` (`AccessoryViews`, `AppearanceView`, `BoardView`, `DataTransferView`, `MarkdownPreview`, `NativeEditor`, `NoteView`, `PRCard`, `SettingsView`); test `AppTests/AppearanceIntegrationTests.swift`.

**Interfaces:**
- Produces:
  - `ThemeController` has an internal `init()` and no `shared`. It exposes `var snapshot: StowTheme`.
  - `struct StowTheme: Equatable, Sendable` holds `settings` and `reduceTransparency`, plus `colorScheme`, `effectiveBackgroundOpacity`, and `func font(size: CGFloat = 13, weight: Font.Weight = .regular) -> Font`.
  - `EnvironmentValues.stowTheme` defaults to `StowTheme(settings: .default, reduceTransparency: false)`.
  - `struct StowColor: ShapeStyle` resolves its role from `environment.stowTheme`, with static `.stowBackground`, `.stowSurface`, `.stowNote`, `.stowText`, `.stowMuted`, `.stowAmber`, `.stowRed`, and `.stowGreen`.
  - `AppStore` gains `let theme: ThemeController`.

- [ ] **Step 1: Write the failing test** `testThemesDoNotBleedBetweenStores`. Two stores in separate temporary folders apply dark and light settings; `a.theme.snapshot.colorScheme == .dark` and `b.theme.snapshot.colorScheme == .light`.
- [ ] **Step 2: Run hosted `AppearanceIntegrationTests`.** Expected: compile failure, because `theme` is missing.
- [ ] **Step 3: Convert the views.**
  - Root views inject `.environment(\.stowTheme, store.theme.snapshot)`.
  - Views read `@Environment(\.stowTheme)` and use `theme.font(…)` and `.stowX` styles.
  - Panels take `NSAppearance` from their own store's theme.
  - `NativeEditor` and `MarkdownPreview` receive the theme from their parent view.
- [ ] **Step 4: Run `./scripts/test.sh`.** Expected: every test passes, and `grep -rn "ThemeController.shared" App` prints nothing.
- [ ] **Step 5: Commit** `refactor(app): give each store its own theme`.

### Task 8: run the board as a profile session

**Files:** create `App/ProfileSession.swift`, `App/ProfileManager.swift`, and `AppTests/ProfileTests.swift`; modify `App/Windows.swift`, `App/SmokeTest.swift`, and `Stow.xcodeproj/project.pbxproj`.

**Interfaces:**
- Consumes: tasks 1 to 7.
- Produces:

```swift
@MainActor final class ProfileSession {
    let entry: ProfileEntry
    let store: AppStore
    private(set) var board: StowPanel!
    private(set) var noteWindows: [UUID: StowPanel]
    var settingsWindow: NSWindow?
    private(set) var isHidden: Bool
    func start() async
    func showBoard()
    func showNote(_ id: UUID)
}
@MainActor final class ProfileManager {
    init(dataFolder: URL, isDemo: Bool, catalog: ProfileCatalog? = nil)
    private(set) var profiles: [ProfileEntry]
    private(set) var sessions: [UUID: ProfileSession]
    private(set) var lastActiveID: UUID?
    var showsProfileNames: Bool { get }      // more than one profile, or the index setting
    var activeSession: ProfileSession? { get } // key window's profile, else lastActiveID, else the first open
    func start() async -> Bool                // false when no profile could open because locks are held elsewhere
}
// AppDelegate keeps prepare(stateURL:isDemo:) (data folder = the folder of stateURL) and
// store, board, noteWindows as accessors forwarding to manager.activeSession.
```

- [ ] **Step 1: Write the failing tests:**
  - `testDataFolderOpensAsSingleProfileWithoutWritingIndex`: neither `profiles.json` nor `identity.json` appears.
  - `testProfileLockedElsewhereStaysClosed`: the test holds `StateLock.acquire(forStateAt:)` for the folder; `start()` returns false and `sessions` is empty.
- [ ] **Step 2: Run hosted `ProfileTests`.** Expected: compile failure.
- [ ] **Step 3: Move the per-profile window code out of `AppDelegate` into `ProfileSession`.**
  - `AppDelegate` takes `StateLock.acquire(named: StateLock.instanceFilename, in: dataFolder)` at launch. If it is held, or if `start()` returns false, it hands over with the existing `activateRunningCopy()` and terminates.
  - Sessions check `sessions[id]` before taking their `.stow.lock`.
  - `--stow-testing-state <folder>` now names the data folder, and its guard against the real data folder stays.
  - With one profile, titles stay "Stow", "Stow note", and "Stow settings".
- [ ] **Step 4: Regenerate the project with XcodeGen** and keep the package reference named `stow`. Run `./scripts/test.sh`. Expected: every existing hosted test and the smoke test pass unchanged, plus the two new tests.
- [ ] **Step 5: Commit** `refactor(app): run the board as a profile session`.

### Task 9: open, hide, show, and close profiles

**Files:** modify `App/ProfileSession.swift`, `App/ProfileManager.swift`, and `App/AppStore.swift`; test `AppTests/ProfileTests.swift`.

**Interfaces:**
- Produces:
  - `ProfileManager.open(_ id: UUID) async`, which brings windows forward if the profile is already open;
  - `ProfileManager.hide(_ id: UUID)` and `ProfileManager.show(_ id: UUID)`;
  - `ProfileManager.switchTo(_ id: UUID) async` *(owner request)*: opens the target if needed and brings its windows forward, then hides the profile it left when that profile's `AppState.hidesWhenSwitchingAway` is true;
  - `AppState.hidesWhenSwitchingAway: Bool`, decoded with `decodeIfPresent` and default `true`, travelling in backups like the other preferences *(owner request)*;
  - `ProfileManager.close(_ id: UUID) async -> Bool`;
  - `AppStore.isPaused: Bool`, under which refresh, timers, and accessories do nothing; setting it to false refreshes;
  - `AppStore.init(…, arrival: Bool = false)`, which applies `preparedForArrival()` after loading and saves.

- [ ] **Step 1: Write the failing tests:**
  - `testTwoProfilesStayIsolated`: a note added in each profile appears only in that profile's `state.json` and notes folder, and the boards are titled "Stow" and "Work".
  - `testHideOrdersOutEveryWindowAndPausesRefresh`: no window is visible and none is miniaturized; a scripted client sees no refresh while hidden and one refresh on show.
  - `testHideKeepsAlwaysOnTopNotesWhenEnabled`.
  - `testOpeningAnOpenProfileBringsItForward`: there is still one session, and its board becomes key.
  - `testRapidHideShowCloseOpenLeavesConsistentState`: twenty mixed operations without awaiting each other leave one session or none per profile, no orphan windows, and every held lock belonging to an open session.
  - `testCloseReleasesLockAndReopenRestoresWindows`: after close, the test can take the profile's lock; reopening brings back the board and the detached note.
  - `testRefreshFinishingAfterCloseWritesNothing` *(review focus 1)*: a delayed client is mid-refresh when the profile closes; after it completes, `state.json` bytes are unchanged and the other profile is untouched.
  - `testExternalEditWhileHiddenIsKept` *(review focus 2)*: rewrite the note file while the profile is hidden; after show and flush, the note has the new text and there are no conflict copies.
  - `testArrivalProfileOpensWithGitHubAndAccessoriesOff`: GitHub is off, the `gh` location is nil, accessories are disabled, and `seenIDs` gains the ID.
  - `testSwitchShowsTargetAndHidesSourceByDefault` *(owner request)*: right after `switchTo(B)` returns, B's board is visible and key and A's windows are ordered out (not miniaturized).
  - `testSwitchKeepsSourceWhenSettingIsOff` *(owner request)*: with A's `hidesWhenSwitchingAway` false, A's windows stay visible.
  - `testSwitchOpensAClosedProfile` *(owner request)*.
- [ ] **Step 2: Run hosted `ProfileTests`.** Expected: the new tests fail.
- [ ] **Step 3: Implement the lifecycle.**
  - Hide uses `orderOut`, never `miniaturize`.
  - Show restores frames and levels.
  - Close flushes; on failure it asks "Keep open" or "Close without saving". Then it stops the store, closes the windows, calls `saveAndClose`, and releases the lock.
  - When names show, titles are "<name>", "<name> note", and "<name> settings".
  - After opening an arrival, call `catalog.markSeen`.
  - A switch orders windows in and out at once, without animation that delays it, and respects Reduce Motion *(owner request)*.
  - When a session's window becomes key, that profile becomes `lastActiveID`.
  - The data folder profile's default name changes from "Main" to "Stow", both as the fallback in `ProfileCatalog` and in the identity file written by the first index write. Update the core tests to match. The board title then stays "Stow" for one profile once task 12 makes the title the profile name.
- [ ] **Step 4: Run hosted `ProfileTests`.** Expected: pass.
- [ ] **Step 5: Commit** `feat(app): hide, show, and close profiles`.

### Task 10: restore at launch and save at quit

**Files:** modify `App/ProfileManager.swift`, `App/Windows.swift`, and `App/AppStore.swift`; test `AppTests/ProfileTests.swift`.

**Interfaces:**
- Produces:
  - `ProfileManager.terminationSave() async -> [UUID: Bool]`;
  - `ProfileManager.cancelTermination()`, which makes every session writable again and calls `StateRepository.reopen()` where a save closed the repository;
  - `ProfileManager.recordSession()`, which writes the open and hidden profiles and `lastActiveID`, and does nothing while there is no index and only the data folder profile is open.

- [ ] **Step 1: Write the failing tests:**
  - `testRelaunchRestoresOpenAndHiddenProfiles`;
  - `testLaunchWithNothingVisibleShowsLastActive`;
  - `testFirstLaunchAfterUpgradeOpensOnlyTheFirstProfile`;
  - `testKeepOpenAfterPartialQuitFailureKeepsEveryProfileWritable`: with B's notes folder unwritable, `terminationSave()` returns A true and B false. After `cancelTermination()`, an edit in A flushes, and A's `state.json` contains it.
- [ ] **Step 2: Run hosted `ProfileTests`.** Expected: the new tests fail.
- [ ] **Step 3: Implement launch restore and quit.** `applicationShouldTerminate` uses `terminationSave()`. The existing alert names the profiles that failed, and **Keep open** calls `cancelTermination()`.
- [ ] **Step 4: Run hosted `ProfileTests` and `AppIntegrationTests`.** Expected: pass.
- [ ] **Step 5: Commit** `feat(app): restore profiles at launch and save each at quit`.

### Task 11: profile-aware menus

**Files:** modify `App/Windows.swift` and `App/ProfileManager.swift`; test `AppTests/ProfileTests.swift`.

**Interfaces:**
- Produces: `AppDelegate.applicationDockMenu(_:)`, a File menu **New profile…** item, and menu titles refreshed through `NSMenuDelegate.menuNeedsUpdate(_:)`.
- Produces *(owner request)*: a Profiles menu listing every profile in order. Items 1 through 9 carry ⌃⌥1 through ⌃⌥9, and **Next profile** (⌃⌥]) and **Previous profile** (⌃⌥[) wrap around. All of them call `ProfileManager.switchTo(_:)`. These are menu key equivalents, so they work only while Stow is active.

- [ ] **Step 1: Write the failing tests:**
  - `testNewNoteGoesToKeyWindowProfile`;
  - `testMenuTitlesNameProfileOnlyWithSeveralProfiles`: titles read "New note in Work" with two profiles and "New note" with one;
  - `testDockMenuListsProfilesWithState`: a visible profile is `.on`, a hidden one `.mixed`, a closed one `.off`; with one profile the menu has only "New profile…";
  - `testDockReopenShowsMostRecentProfile`.
  - `testProfilesMenuShortcutsFollowOrder` *(owner request)*: with three profiles, the items carry ⌃⌥1, ⌃⌥2, and ⌃⌥3 in profile order; after reordering, the shortcuts follow the new order.
  - `testNextAndPreviousProfileWrap` *(owner request)*: from the last profile, Next switches to the first; from the first, Previous switches to the last.
  - `testDockMenuSwitches` *(owner request)*: choosing a profile in the Dock menu calls the same switch, so the source hides by default.
- [ ] **Step 2: Run hosted `ProfileTests`.** Expected: the new tests fail.
- [ ] **Step 3: Implement the menus.** New note, Refresh GitHub, Settings…, and Show board act on `activeSession`. `applicationShouldHandleReopen` shows or opens the most recently active profile.
- [ ] **Step 4: Run hosted `ProfileTests`.** Expected: pass.
- [ ] **Step 5: Commit** `feat(app): profile-aware menus and Dock menu`.

### Task 12: manage profiles

**Files:** create `App/ProfilesSettingsView.swift`; modify `App/SettingsView.swift`, `App/BoardView.swift`, `App/NoteView.swift`, `App/ProfileManager.swift`, and `Stow.xcodeproj/project.pbxproj`; test `AppTests/ProfileTests.swift`.

**Interfaces:**
- Consumes: task 4 changes and task 5 `trash`.
- Produces: `ProfileManager.createProfile(name:color:)`, `rename(_:to:)`, `setColor(_:to:)`, `move(_:by:)`, `delete(_:)`, `resetIndex()`, and `setAlwaysShowProfileName(_:)`. Each is `async throws` and forwards to the catalog.
- Produces *(owner request)*: profile icons in core and app.
  - `ProfileIcon: Codable, Equatable, Sendable` has `case symbol(String)` and `case emoji(String)`.
  - `ProfileIdentity.icon: ProfileIcon?` and `ProfileEntry.icon: ProfileIcon?`.
  - `ProfileIcon.validated(_:) -> ProfileIcon?`. A symbol name is 1–64 ASCII letters, digits, and dots. An emoji is exactly one `Character` of at most 32 UTF-8 bytes with at least one scalar whose `properties.isEmoji` is true.
  - An invalid icon in an identity file decodes as nil without rejecting the identity.
  - `ProfileCatalog.setIcon(_ id: UUID, to icon: ProfileIcon?) throws`, with the same refusal rule as `setColor` when the identity file is unreadable, and `ProfileManager.setIcon(_:to:) async throws`.
  - The app also checks that a symbol exists (`NSImage(systemSymbolName:accessibilityDescription:)`) before showing it, and shows nothing otherwise.

- [ ] **Step 1: Write the failing tests:**
  - `testNewProfileStartsEmptyWithGitHubOffer`: `offersGitHubSetup` is true, `githubEnabled` false, there are no notes, and the appearance is `.default`;
  - `testRenameRejectsDuplicateName`;
  - `testDeleteClosesAndMovesProfileToTrash`, using an injected catalog with a fake trash;
  - `testNamesAppearOnlyWithTwoProfilesOrSetting`;
  - `testRestoreReplacesOnlyItsProfile`: restoring in B leaves A's files byte-identical.
  - Core, in `Tests/StowCoreTests/ProfileTests.swift` and `ProfileCatalogTests.swift` *(owner request)*:
    - `testIconValidation`: `.symbol("star.fill")` and `.emoji("😀")` are valid; `.symbol("star fill")`, `.symbol("")`, a 65-character symbol name, `.emoji("😀😀")`, and `.emoji("a")` are invalid.
    - `testInvalidIconDecodesAsNil`.
    - `testSetIconPersistsAndClears`.
  - Hosted *(owner request)*: `testBoardHeaderShowsIconWhenSet`, where the header's accessibility label includes the profile name whether or not an icon is set.
- [ ] **Step 2: Run hosted `ProfileTests`.** Expected: the new tests fail.
- [ ] **Step 3: Build the UI.**
  - Settings → Profiles lists each profile with a name field, a color well, up and down buttons, and **Delete…**. It also offers **New profile…** (name and color, with empty and duplicate errors), **Always show profile name**, and **Reset profile list**, shown only while the index needs a reset.
  - A new profile's color defaults to the first color in a small built-in palette that no other profile uses.
  - The board header's icon becomes the profile switcher, and the title becomes the profile's name *(owner request)*. The icon is the profile's icon if set, otherwise the existing tray symbol, tinted with the profile color when colors show. It always opens the profile menu: switch to or open others, Hide, Close, New profile…, and Profile settings. With one profile, the menu offers New profile… and Profile settings.
  - The title text follows `BoardLayout.showsTitle` (Settings → Board → **Show board title**, on by default, per profile). When it is off, only the text hides and the icon switcher stays *(owner request)*.
  - Hosted tests *(owner request)*:
    - `testHeaderTitleIsProfileName`: renaming the profile changes the title.
    - `testHidingTitleKeepsIconSwitcher`: with `showsTitle` false the name text is gone, and the icon button with its menu remains.
  - Detached notes show the accent and name.
  - Settings → Profiles adds an icon picker per profile *(owner request)*: None, a short list of common SF Symbols, a text field for any symbol name, and an emoji field. It also adds the **Hide when switching away** toggle (task 9's `hidesWhenSwitchingAway`) to each profile's Settings.
  - The board header shows color, icon, and name. The icon is decorative for VoiceOver, and the name carries the label.
  - The delete confirmation names the profile.
- [ ] **Step 4: Regenerate the project with XcodeGen** (package reference `stow`). Run `./scripts/test.sh`. Expected: pass.
- [ ] **Step 5: Commit** `feat(app): create, rename, and delete profiles`.

### Task 13: pause a profile on account mismatch

**Files:** modify `Sources/StowGitHub/GHClient.swift`, `Sources/StowGitHub/Transport.swift`, `App/AppStore.swift`, and `App/BoardView.swift`; tests `Tests/StowGitHubTests/GitHubTests.swift` and `AppTests/ProfileTests.swift`.

**Interfaces:**
- Produces: `GitHubError.accountMismatch(actualLogin: String)`, `AppStore.accountMismatch: String?`, and `AppStore.useCurrentAccount()`.

- [ ] **Step 1: Write the failing tests.** Replace `accountSwitchDiscardsPrivateTitlesDetailsAndUnpinnedReferences` with:

```swift
@Test func accountMismatchStopsAfterFirstResponse() async throws {
    let transport = ScriptedTransport([.init("StowViewer", try encoded(fixture()))])
    await #expect(throws: GitHubError.accountMismatch(actualLogin: "synthetic-viewer")) {
        try await GHClient(transport: transport).refresh(pins: [], previous: [], expectedViewerLogin: "old-account")
    }
    #expect(await transport.count == 1)
}
```

Add these hosted tests:
  - `testMismatchPausesAndKeepsCachedCards`;
  - `testUseCurrentAccountClearsCacheKeepsNotesAndPins`;
  - `testDetailsRefusedWhileMismatched`;
  - `testAccountReturningClearsMismatch`.
- [ ] **Step 2: Run `swift test --filter StowGitHubTests` and hosted `ProfileTests`.** Expected: failures.
- [ ] **Step 3: Implement the mismatch flow.**
  - `GHClient.refresh` throws right after the first response when the expected login differs, ignoring case.
  - `AppStore` treats a result with a different login the same way, as a guard for injected clients. It marks cards stale and shows the banner "GitHub is signed in as \(actual). This profile uses \(expected)." with the button "Use \(actual) here".
  - `useCurrentAccount()` clears `pullRequests`, `dismissedIDs`, `expandedPRs`, and detail tasks, sets `viewerLogin`, and refreshes.
- [ ] **Step 4: Run both test commands.** Expected: pass.
- [ ] **Step 5: Commit** `feat(github): pause a profile when gh answers as another account`.

### Task 14: share one GitHub client per gh location

**Files:** modify `App/ProfileManager.swift` and `App/AppStore.swift`; test `AppTests/ProfileTests.swift`.

**Interfaces:**
- Produces:
  - `ProfileManager.githubClient(for executable: URL) -> any GitHubClient`, cached by `executable.resolvingSymlinksInPath().path`;
  - `AppStore.init(…, githubClientFactory: (@MainActor (URL) -> any GitHubClient)? = nil)`, used by `configureGitHub()` in place of creating a `GHClient` directly.

- [ ] **Step 1: Write the failing tests:**
  - `testProfilesShareOneClientPerGHLocation`: two sessions with the same `gh` path get the identical client (`===`);
  - `testRateLimitPausesEveryProfileOnTheClient`: a scripted transport returns 429 for A's refresh; B's refresh then throws `.rateLimited` without a new transport call.
- [ ] **Step 2: Run hosted `ProfileTests`.** Expected: failures.
- [ ] **Step 3: Implement the client cache and the factory.**
- [ ] **Step 4: Run hosted `ProfileTests`.** Expected: pass.
- [ ] **Step 5: Commit** `feat(github): share rate-limit backoff across profiles`.

### Task 15: owner rules

**Files:** create `Sources/StowCore/Owners.swift`; test `Tests/StowCoreTests/OwnerTests.swift`.

**Interfaces:**
- Consumes: `OwnerSelection` and `BoardLayout.OwnerOrder` from task 6.
- Produces:

```swift
public struct OwnerSummary: Equatable, Sendable { public var owner: String; public var cardCount: Int; public var isSelected: Bool }
public func ownerSummaries(pullRequests: [PullRequestSnapshot], pins: [PullRequestReference], dismissedIDs: [String],
                           selection: OwnerSelection, order: BoardLayout.OwnerOrder) -> [OwnerSummary]
public func isShown(_ snapshot: PullRequestSnapshot, selection: OwnerSelection, pins: [PullRequestReference]) -> Bool
public func groupedByOwner(_ cards: [PullRequestSnapshot], order: BoardLayout.OwnerOrder) -> [(owner: String, cards: [PullRequestSnapshot])]
public func retainingSelectedOwners(_ snapshots: [PullRequestSnapshot], selection: OwnerSelection,
                                    pins: [PullRequestReference]) -> [PullRequestSnapshot]
public func showsOwnerControl(githubEnabled: Bool, pullRequests: [PullRequestSnapshot], selection: OwnerSelection,
                              alwaysShow: Bool) -> Bool
public func isNoteShown(_ note: Note, selection: OwnerSelection, hidesLinkedNotes: Bool) -> Bool
```

- [ ] **Step 1: Write the failing tests:**
  - `testSummariesCountUndismissedCardsAndKeepSelectedOwnersWithoutCards`: a selected owner with no cards is listed with count 0;
  - `testOwnerMatchingIgnoresCase` *(review focus 5)*: a card owned by "Acme" is shown for the selection `["acme"]`, and the summaries hold one entry spelled "Acme";
  - `testPinsAlwaysShow`;
  - `testGroupingKeepsCardOrderAndSortsOwners`: alphabetical order, and most-cards order with ties broken A to Z;
  - `testRetainingKeepsPinsAndSelectedOwners`;
  - `testOwnerControlVisibility`: one owner with All gives false; two owners true; an active selection true; GitHub off false; `alwaysShow` with GitHub on true;
  - `testLinkedNotesHideOnlyWhenEnabled`: standalone notes always show.
- [ ] **Step 2: Run `swift test --filter OwnerTests`.** Expected: compile failure.
- [ ] **Step 3: Implement the pure functions.** Group order uses a case-insensitive localized compare.
- [ ] **Step 4: Run `swift test --filter OwnerTests`.** Expected: pass.
- [ ] **Step 5: Commit** `feat(core): owner selection rules`.

### Task 16: owner control, grouping, and the note filter

**Files:** create `App/OwnerControl.swift`; modify `App/BoardView.swift`, `App/AppStore.swift`, `App/SettingsView.swift`, and `Stow.xcodeproj/project.pbxproj`; test `AppTests/OwnerViewTests.swift` (new).

**Interfaces:**
- Consumes: task 15.
- Produces on `AppStore`:
  - `setOwnerSelection(_ selection: OwnerSelection)`, which saves, and refreshes when keeping only selected owners;
  - `setKeepsOnlySelectedOwners(_ on: Bool)`, which prunes at once when turned on;
  - `var ownerSummaries: [OwnerSummary]`, built from the cache, or from the latest refresh kept in memory while pruning;
  - `var visibleNotes: [Note]`;
  - `cards(in:)`, which now applies `isShown`.

- [ ] **Step 1: Write the failing tests:**
  - `testSelectionHidesOtherOwnersButNotPinsOrWarnings`;
  - `testClassificationIsUnchangedUnderSelection`;
  - `testKeepOnlySelectedOwnersPrunesStateAndBackup`: neither `state.json` nor `StowBackup.encode` contains the other owner's synthetic title;
  - `testLinkedNotesHiddenOnlyWithSetting`: the Notes header shows the hidden count.
- [ ] **Step 2: Run hosted `OwnerViewTests`.** Expected: compile failure.
- [ ] **Step 3: Build the UI.**
  - The header control shows when `showsOwnerControl` is true. Its menu offers All owners, each owner as "name (count)" with a checkmark, and **Add owner…**, which validates with `OwnerSelection.isValidLogin`.
  - Settings → Board adds Group by owner, Owner order, Always show owner control, Hide notes linked to hidden owners, Keep only selected owners on disk, and Keep always-on-top notes visible when hiding.
  - Owner subheadings with counts sit inside Needs you and Waiting, and Show more counts cards per section.
- [ ] **Step 4: Regenerate the project with XcodeGen** (package reference `stow`). Run `./scripts/test.sh`. Expected: pass.
- [ ] **Step 5: Commit** `feat(board): filter and group pull requests by owner`.

### Task 17: documentation and verification

**Files:** modify `docs/architecture.md`, `docs/privacy.md`, `docs/portability.md`, `docs/verification.md`, `docs/roadmap.md`, `AGENTS.md`, and `README.md`.

- [ ] **Step 1: Update the documents.**
  - Architecture and privacy describe the profiles folder, identity files, the index, both locks, per-profile backups, Trash retention, profile names in window titles, and the mismatch flow.
  - `AGENTS.md` invariants say every profile has its own lock and the process holds `.stow-app.lock`. New profiles and profiles not seen before never turn GitHub or accessories on, and a different account pauses the profile.
  - `verification.md` gains manual checks from the design's acceptance section.
  - `roadmap.md` §2 ticks the profile items that shipped.
- [ ] **Step 2: Run `./scripts/test.sh`, `./scripts/build.sh Debug`, and `./scripts/build.sh Release`.** Expected: all pass, and `git diff --check` is clean. Record the results as evidence in `verification.md`.
- [ ] **Step 3: Run the manual checks with synthetic state and record what you observed**, including what you could not check. Include a second launch handing over to the running copy, and an older build opening the first profile while the new build leaves it closed.
- [ ] **Step 4: Commit** `docs: describe profiles and owner views`.
