import Foundation

extension Date {
    /// A steady, short age like "2m ago", or "just now" in the first minute, for labels that update each minute.
    public func shortAge(relativeTo now: Date = .now, locale: Locale = .current) -> String {
        guard now.timeIntervalSince(self) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = locale
        return formatter.localizedString(for: self, relativeTo: now)
    }
}
