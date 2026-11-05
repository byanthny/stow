import StowCore
import SwiftUI

struct PRCard: View {
    let store: AppStore
    @Environment(\.stowTheme) private var theme
    let pr: PullRequestSnapshot
    private var pinned: Bool { store.state.pins.contains(pr.reference) }
    private var classification: AttentionClassification { classify(pr, isPinned: pinned) }
    private var expanded: Bool { store.expandedPRs.contains(pr.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Button {
                    AppStore.openLink(pr.reference.url)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        // Lead with the repository so cards from different repos are easy to tell apart.
                        if pr.title != pr.reference.displayName {
                            // The repository's own color picks out "/repo", so cards from one repo match at a glance.
                            let surface = theme.settings.colors.surface
                            let repository = Color(stowHex: RepositoryColor.hex(for: pr.reference, onSurface: surface))
                            (Text(verbatim: pr.reference.owner).foregroundStyle(.stowText)
                                + Text(verbatim: "/\(pr.reference.repository)").foregroundStyle(repository)
                                + Text(verbatim: " #\(pr.reference.number)").font(theme.font(size: 10))
                                .foregroundStyle(.stowMuted))
                                .font(theme.font(size: 10, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        }
                        Text(pr.title).font(theme.font(size: 12, weight: .medium)).foregroundStyle(.stowText)
                            .multilineTextAlignment(.leading).lineLimit(3)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help("Open pull request")
                // The card's actions sit beside its expand button, one click away.
                CardIconButton(
                    symbol: pinned ? "pin.fill" : "pin", label: pinned ? "Unpin pull request" : "Pin pull request",
                    identifier: "card.pin", scale: .small
                ) { store.togglePin(pr.reference) }
                CardIconButton(symbol: "square.and.pencil", label: "Add personal note", identifier: "card.addNote") {
                    store.addNote(reference: pr.reference)
                }
                CardIconButton(symbol: "xmark", label: "Dismiss pull request", identifier: "card.dismiss") {
                    store.dismiss(pr.reference)
                }
                Button {
                    store.toggleDetails(pr.reference)
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(theme.font(size: 9, weight: .medium))
                        .frame(width: 18, height: 22)
                }.buttonStyle(.plain).foregroundStyle(.stowMuted).accessibilityLabel(
                    expanded ? "Collapse pull request" : "Expand pull request")
            }
            // The state on one line and the checks, always, on the next.
            let status = pr.cardStatus(under: classification)
            Button {
                store.toggleDetails(pr.reference)
            } label: {
                HStack(spacing: 8) {
                    if let headline = status.headline {
                        Text(headline).font(theme.font(size: 11)).foregroundStyle(toneColor(status.tone))
                    }
                    ForEach(status.notes, id: \.self) { note in
                        Text(note).font(theme.font(size: 10)).foregroundStyle(.stowMuted)
                    }
                    Spacer(minLength: 0)
                    activity
                }.lineLimit(1).contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack(spacing: 3) {
                if let tone = status.checks.tone { checksIcon(tone) }
                Text(status.checks.label)
            }.font(theme.font(size: 10)).foregroundStyle(.stowMuted).lineLimit(1)
            if expanded { details }
        }.padding(12).background(.stowSurface, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.035)) }
            .contextMenu {
                Button(pinned ? "Unpin" : "Pin") { store.togglePin(pr.reference) }
                Button("Add personal note") { store.addNote(reference: pr.reference) }
                Button("Dismiss") { store.dismiss(pr.reference) }
            }
    }

    /// When the pull request last changed, kept current each minute, and a clock when Stow couldn't refresh it.
    private var activity: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 3) {
                if pr.isStale || pr.isUnavailable {
                    Image(systemName: "clock").accessibilityLabel("Not refreshed")
                        .help("Stow couldn't refresh this card, so it shows what GitHub said last time.")
                }
                if let updated = pr.updatedAt {
                    Text("Active \(updated.shortAge(relativeTo: context.date))")
                }
            }
        }
        .font(theme.font(size: 10)).foregroundStyle(.stowMuted)
    }

    private func checksIcon(_ tone: AttentionTone) -> some View {
        Image(systemName: checksSymbol(tone)).font(theme.font(size: tone == .pending ? 6 : 9))
            .foregroundStyle(toneColor(tone)).accessibilityHidden(true)
    }

    @ViewBuilder private var details: some View {
        Divider().overlay(.white.opacity(0.03)).padding(.vertical, 2)
        if store.loadingDetails.contains(pr.id) { ProgressView().controlSize(.small) }
        if let details = pr.details {
            ForEach(Array(details.checks.enumerated()), id: \.offset) { _, check in
                HStack(spacing: 6) {
                    Image(systemName: checkSymbol(check.state)).foregroundStyle(toneColor(checkTone(check.state)))
                    if let url = check.url {
                        Button(check.name) { AppStore.openLink(url) }.buttonStyle(.plain).underline()
                    } else {
                        Text(check.name)
                    }
                    Spacer(minLength: 4)
                    Text(check.state.lowercased().replacingOccurrences(of: "_", with: " "))
                        .font(theme.font(size: 10)).lineLimit(1)
                }.font(theme.font(size: 10)).foregroundStyle(.stowMuted)
            }
            ForEach(Array(details.reviews.enumerated()), id: \.offset) { _, review in
                Text("\(review.author): \(review.state.lowercased().replacingOccurrences(of: "_", with: " "))")
                    .font(theme.font(size: 10)).foregroundStyle(.stowMuted)
            }
            if let unresolved = details.unresolvedThreadCount {
                Text("\(unresolved) unresolved \(unresolved == 1 ? "thread" : "threads")").font(theme.font(size: 10))
                    .foregroundStyle(.stowMuted)
            }
            if let comment = details.latestComment {
                Text(comment).font(theme.font(size: 11)).foregroundStyle(.stowMuted).lineLimit(4).textSelection(
                    .enabled)
            }
            if let commits = details.commits, !commits.isEmpty {
                Text("Recent commits").font(theme.font(size: 10, weight: .medium)).foregroundStyle(.stowMuted)
                ForEach(Array(commits.enumerated()), id: \.offset) { _, commit in
                    HStack(spacing: 6) {
                        Text(commit.headline).lineLimit(1)
                        Spacer(minLength: 4)
                        if let date = commit.committedAt { Text(date.shortAge()) }
                    }.font(theme.font(size: 10)).foregroundStyle(.stowMuted)
                }
            }
            if !details.isComplete {
                Text("Some details are unavailable.").font(theme.font(size: 9)).foregroundStyle(.stowAmber)
            }
        } else if !store.loadingDetails.contains(pr.id) {
            Text("Details are unavailable offline.").font(theme.font(size: 10)).foregroundStyle(.stowMuted)
        }
        // Ages line up on the right, like the commit times above them.
        Group {
            if let created = pr.createdAt { Text("Opened \(created.shortAge())") }
            Text("State observed \(pr.observedStateSince.shortAge())")
        }.font(theme.font(size: 10)).foregroundStyle(.stowMuted).frame(maxWidth: .infinity, alignment: .trailing)
        ForEach(store.state.notes.filter { $0.pullRequest?.id == pr.id }) { note in
            Button {
                if note.isDetached {
                    store.detachNote(note.id)
                } else {
                    store.requestFocus(note.id)
                    store.onShowBoard?()
                }
            } label: {
                Label(
                    note.title ?? "Personal note",
                    systemImage: "doc.text"
                )
                .lineLimit(1).font(theme.font(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.stowMuted)
        }
    }
}

/// A status color for a tone, like GitHub's: green, red, amber, or muted.
func toneColor(_ tone: AttentionTone) -> StowColor {
    switch tone {
    case .success: .stowGreen
    case .failure: .stowRed
    case .pending: .stowAmber
    case .neutral: .stowMuted
    }
}

/// The checks icon GitHub shows beside a pull request: a check, a cross, or a dot while they run.
private func checksSymbol(_ tone: AttentionTone) -> String {
    switch tone {
    case .success: "checkmark.circle.fill"
    case .failure: "xmark.circle.fill"
    case .pending, .neutral: "circle.fill"
    }
}

func checkSymbol(_ state: String) -> String {
    switch state {
    case "SUCCESS", "NEUTRAL", "SKIPPED": "checkmark.circle"
    case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": "xmark.circle"
    case "PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED": "clock"
    default: "questionmark.circle"
    }
}

/// A small action icon on a card, sized like the card's expand button.
struct CardIconButton: View {
    let symbol: String
    let label: String
    let identifier: String
    var scale: Image.Scale = .medium
    var action: () -> Void
    @Environment(\.stowTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(theme.font(size: 9, weight: .medium)).imageScale(scale)
                .frame(width: 18, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.stowMuted)
        .help(label).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}
