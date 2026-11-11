# Modules

**Planned.** This is the design for 0.5.0 and 0.6.0 in the [plan to v1](v1-plan.md); none of it is built yet. Today's accessory contract is in [providers](providers.md).

Stow is a notes app first. A module adds sections and cards to the board, and GitHub becomes one. With every module off, the board shows only Notes. Modules are compiled into the app for v1; installable modules come later.

## Module interface

SDK v2, in `Sources/StowExtensionSDK`.

Foundation only. Every value is Codable, Equatable and Sendable. The host caps every string and count. v1 accessories keep working unchanged.

```swift
public protocol StowModule: Sendable {
    var descriptor: AccessoryDescriptor { get }        // apiVersion: 2
    var manifest: ModuleManifest { get }                // plain data; the host reads it without running the module
    func refresh(_ r: ModuleRequest) async throws -> ModuleRefreshResult
    func render(_ r: ModuleRequest) async throws -> ModuleBoard             // local only, never network
    func details(_ r: ModuleDetailsRequest) async throws -> ModuleDetailsResult
    func perform(_ r: ModuleCommandRequest) async throws -> ModuleCommandResult
    func validate(_ r: ModuleInputRequest) async throws -> String?         // nil means valid
}   // details, perform and validate default to `throw ModuleError.unsupported`

public struct ModuleManifest {
    var stateVersion: Int
    var enableTitle: String                    // "Show pull requests"
    var refresh: RefreshPolicy                 // intervalSeconds >= 60, timeoutSeconds <= 300, onActivation
    var sections: [ModuleSectionSpec]          // id, title, emptyText, raisesAttention
    var facets: [ModuleFacetSpec]              // id, title, noun, ignoresCase, groups, acceptsCustomValues
    var settings: [ModuleSettingSpec]          // toggle, path, text, choice, button, info; isMachineLocal
    var commands: [ModuleCommandSpec]          // id, title, symbol, placements
    var linkPatterns: [ModuleLinkPattern]      // host, anchored path regex, item id template, onPaste
    var reportsIdentity: Bool
    var hasDetails: Bool
    var offer: ModuleOffer?                    // first-launch question; built-in modules only
}
public struct ModuleRequest {
    var instanceID: UUID
    var revision: UInt64                       // echoed back; older revisions are rejected
    var requestedAt: Date
    var configuration: JSONValue
    var state: ModuleState                     // saved by the host
    var session: JSONValue                     // memory only
    var pins: [ModulePin]
    var facetSelections: [String: [String]]
    var expectedIdentity: ModuleIdentity?
    var isStale: Bool                          // nothing confirmed this session
}
public struct ModuleRefreshResult { var revision: UInt64; var state: ModuleState; var session: JSONValue
                                    var identity: ModuleIdentity?; var board: ModuleBoard }
public struct ModuleBoard { var cards: [ModuleCard]; var banners: [ModuleBanner]; var wantsRefresh: Bool }
public struct ModuleCard: Identifiable {
    var id: String                    // opaque, 1-256 UTF-8 bytes, unique within the module
    var sectionID: String             // one of the module's sections, or the shared "stow.watching"
    var eyebrow: [TextRun]            // "acme" + "/app" (accent) + " #27" (muted)
    var title: String
    var link: String?                 // http(s), no user info
    var status: StatusLine?           // headline, tone, notes
    var indicator: Indicator?         // label and tone; the tone picks the host's icon
    var timestamp: Timestamp?         // ("Active", date); the host keeps the age current
    var isStale: Bool
    var outline: AccessoryTone?       // green for approved
    var facetValues: [String: String] // ["owner": "acme"]
    var summary: String?              // shown when the section is collapsed
    var facts: [Timestamp]            // Opened, State observed
    var hasDetails: Bool
    var actions: CardActions          // pin, dismiss, addNote
    var links: [CardLink]
}
public struct ModuleDetails { var blocks: [DetailBlock]; var isComplete: Bool; var fetchedAt: Date }
public enum ModuleError: Error, Codable { case unsupported, identityMismatch(ModuleIdentity), failed(String) }
```

## What the host owns

- **Refresh:** cadence from the manifest; one refresh in flight per instance; cancellation on disable, pause, stop, restore or identity change; a timeout held to 10–300 s; a result is committed only if its revision, enablement and identity still match and it passes validation. A failure keeps the last good board, shown stale.
- **Pins and dismissals,** keyed by (moduleID, itemID).
- **Facets:** counts, selection, grouping, order, and hiding linked notes. Pinned cards always show.
- **Identity:** the module reports its account; the host stores the expected one and checks every result. A mismatch pauses the module. "Use X here" clears that module's state and dismissals and keeps pins, notes and selections.
- **Settings:** rendered from declarative specs, so GitHub uses the same path any module would.
- **Paste:** link patterns are matched for every registered module without running module code, so pasting a pull request link still pins it with GitHub off.
- **Caps:** 1,000 cards; ids of 256 bytes; titles of 512 bytes; web-only URLs; 3 banners; 8 detail blocks. A result that breaks a cap is rejected whole.
- **Machine-local settings** (the `gh` path, module switches): read from a per-Mac store outside the data folder, never from profile files.

## GitHub data until v1

GitHub data stays in today's `state.json` keys. A pure `GitHubSchema1Binding` in StowCore maps them into the module's namespace on load and writes them back byte-identically.

| Key on disk | In memory |
| --- | --- |
| `pullRequests` | module state, plus per-item detail records |
| `pins`, `dismissedIDs` | host pins and dismissals for `github` |
| `ownerSelection`, `boardLayout.groupByOwner`, `ownerOrder`, `alwaysShowOwnerControl`, `hidesNotesForHiddenOwners` | the `owner` facet's selection and display preferences |
| `keepsOnlySelectedOwners` | a GitHub setting |
| `ghExecutablePath`, `githubEnabled` | a mirror of the per-Mac store, written for 0.3.x and never read back |
| `viewerLogin`, `lastRefreshAt` | expected identity, last refresh time |
| `notes[].pullRequest` | an item link to (`github`, reference id) |
| `boardLayout.order` entries `needsYou`, `waiting` | GitHub section keys |

## Note links

In `Sources/StowCore/Models.swift`.

```swift
public struct ModuleItemLink { var key: ModuleItemKey; var title: String?; var facets: [String: String] }
public struct WebLink { public let url: URL; public init?(_ string: String) }   // http(s), host, no user info, <= 2,048 bytes
public enum NoteLink { case item(ModuleItemLink), web(WebLink) }
// Note gets `var link: NoteLink?` and a custom Codable. `pullRequest` stays as a computed property until its callers are gone.
```

```json
"pullRequest": {"host":"github.com","number":27,"owner":"example","repository":"desktop"}
"moduleItem":  {"itemID":"sample-2","moduleID":"org.stow.sample","title":"Synthetic item two"}
"webLink":     {"url":"https://example.com/spec"}
```

- `pullRequest` keeps its exact bytes and stays strict. `moduleItem` and `webLink` never throw: a bad value drops the link.
- If several keys are present, the order is `pullRequest`, `moduleItem`, `webLink`.
- A web link that matches a module's link pattern becomes that module's item link when it's created.
- **Placement:** under its card when the card is on the board; in Notes when it isn't; hidden only by a facet set to hide linked notes. Each note shows in exactly one place. A card with notes always shows.
- The conflict copy in `mergeLiveResult` (`App/AppStore.swift:873`) must copy `link`.
