import StowCore
import SwiftUI

struct PRCard: View {
    let store: AppStore
    @Environment(\.stowTheme) private var theme
    let pr: PullRequestSnapshot
    private var pinned: Bool { store.state.pins.contains(pr.reference) }
    private var classification: AttentionClassification { classify(pr, isPinned: pinned) }
    private var expanded: Bool { store.expandedPRs.contains(pr.id) }
    private var tone: StowColor {
        if classification.section == .waiting { return .stowMuted }
        if pr.checksState == "FAILURE" || pr.mergeable == "CONFLICTING" { return .stowRed }
        if classification.reason == "Ready to merge" { return .stowGreen }
        return .stowAmber
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Button {
                    AppStore.openLink(pr.reference.url)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        // Lead with the repository so cards from different repos are easy to tell apart.
                        if pr.title != pr.reference.displayName {
                            HStack(spacing: 4) {
                                Text(verbatim: "\(pr.reference.owner)/\(pr.reference.repository)")
                                    .font(theme.font(size: 10, weight: .semibold)).foregroundStyle(.stowText)
                                Text(verbatim: "#\(pr.reference.number)").font(theme.font(size: 10))
                                    .foregroundStyle(.stowMuted)
                            }.lineLimit(1).truncationMode(.middle)
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
            Button {
                store.toggleDetails(pr.reference)
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(tone).frame(width: 5, height: 5)
                    Text(classification.reason).font(theme.font(size: 11)).foregroundStyle(tone)
                    Spacer()
                    if pr.isStale || pr.isUnavailable {
                        Image(systemName: "clock").font(theme.font(size: 9)).foregroundStyle(.stowMuted).help(
                            "Cached observation")
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack(spacing: 10) {
                Text(checkLabel)
                if let review = pr.reviewDecision {
                    Text(
                        review == "APPROVED"
                            ? "Approved" : review == "CHANGES_REQUESTED" ? "Changes requested" : "Review pending")
                }
                if pr.mergeStateStatus == "BEHIND" { Text("Behind base") }
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

    private var checkLabel: String {
        switch pr.checksState {
        case "SUCCESS": "Checks passed"
        case "FAILURE", "ERROR": "Checks failing"
        case "PENDING", "EXPECTED": "Checks running"
        default: pr.checksKnown ? "No checks" : "Checks unknown"
        }
    }

    @ViewBuilder private var details: some View {
        Divider().overlay(.white.opacity(0.03)).padding(.vertical, 2)
        if store.loadingDetails.contains(pr.id) { ProgressView().controlSize(.small) }
        if let details = pr.details {
            ForEach(Array(details.checks.enumerated()), id: \.offset) { _, check in
                HStack(spacing: 6) {
                    Image(systemName: checkSymbol(check.state))
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
            if !details.isComplete {
                Text("Some details are unavailable.").font(theme.font(size: 9)).foregroundStyle(.stowAmber)
            }
        } else if !store.loadingDetails.contains(pr.id) {
            Text("Details are unavailable offline.").font(theme.font(size: 10)).foregroundStyle(.stowMuted)
        }
        HStack {
            if let created = pr.createdAt { Text("Opened \(created, style: .relative) ago") }
            Spacer(minLength: 0)
            if let updated = pr.updatedAt { Text("Active \(updated, style: .relative) ago") }
        }.font(theme.font(size: 10)).foregroundStyle(.stowMuted)
        Text("State observed \(pr.observedStateSince, style: .relative) ago").font(theme.font(size: 10))
            .foregroundStyle(.stowMuted)
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
                    note.markdown.split(separator: "\n").first.map(String.init) ?? "Personal note",
                    systemImage: "doc.text"
                )
                .lineLimit(1).font(theme.font(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.stowMuted)
        }
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
