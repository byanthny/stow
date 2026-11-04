import Foundation

/// Opt-in local diagnostics contain timings only, never note or GitHub content.
@MainActor
enum LaunchMetrics {
    private static var startedAt: UInt64 = 0
    private static var hasReported = false
    static func begin() { startedAt = DispatchTime.now().uptimeNanoseconds }
    static func firstBoardVisible() {
        guard !hasReported, let path = ProcessInfo.processInfo.environment["STOW_LOCAL_METRICS"] else { return }
        hasReported = true
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        let metrics = ["launchToFirstBoardMilliseconds": elapsed]
        if let data = try? JSONEncoder().encode(metrics) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
