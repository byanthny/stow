import Foundation
import Observation
import SwiftUI

/// A tick once a minute, only while an age shows, that redraws the ages in Stow's windows.
@MainActor @Observable
final class MinuteClock {
    /// The clock every profile's windows share.
    static let shared = MinuteClock()
    /// When the last tick came.
    private(set) var now = Date.now
    /// How many ages show now.
    @ObservationIgnored private(set) var viewers = 0
    @ObservationIgnored private var ticks: Task<Void, Never>?
    @ObservationIgnored private let interval: Duration

    init(interval: Duration = .seconds(60)) { self.interval = interval }

    func addViewer() {
        viewers += 1
        guard ticks == nil else { return }
        now = .now
        ticks = Task { [weak self, interval = self.interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                now = .now
            }
        }
    }

    func removeViewer() {
        viewers = max(viewers - 1, 0)
        guard viewers == 0 else { return }
        ticks?.cancel()
        ticks = nil
    }
}

/// Ages that move on with `clock`, in place of a timer for each view. Only this view redraws on a tick.
struct MinuteAge<Content: View>: View {
    let clock: MinuteClock
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        // Redraws on each tick and shows the current time.
        let _ = clock.now
        content(.now)
            .onAppear { clock.addViewer() }
            .onDisappear { clock.removeViewer() }
    }
}
