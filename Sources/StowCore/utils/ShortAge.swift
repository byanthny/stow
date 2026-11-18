import Foundation

extension Date {
    /// A steady, short age like "2m ago", or "just now" in the first minute, for labels that update each minute.
    public func shortAge(relativeTo now: Date = .now, locale: Locale = .current) -> String {
        guard now.timeIntervalSince(self) >= 60 else { return "just now" }
        return ShortAge.formatters.withValue(for: locale, make: { ShortAge.formatter(locale) }) {
            $0.localizedString(for: self, relativeTo: now)
        }
    }
}

enum ShortAge {
    /// One formatter per locale, each used only while the cache is held.
    static let formatters = BoundedCache<Locale, RelativeDateTimeFormatter>(limit: 8)

    static func formatter(_ locale: Locale) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = locale
        return formatter
    }
}
