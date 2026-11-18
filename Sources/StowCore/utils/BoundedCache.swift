import Foundation

/// Values made once per key and kept, at most `limit` of them, safe to use from any thread. Full, it starts over.
final class BoundedCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var values: [Key: Value] = [:]

    init(limit: Int) { self.limit = limit }

    /// Calls `body` with the value for `key`, made by `make` if there is none, while no other thread uses the cache.
    func withValue<Result>(for key: Key, make: () -> Value, _ body: (Value) -> Result) -> Result {
        lock.withLock {
            if let value = values[key] { return body(value) }
            if values.count >= limit { values.removeAll() }
            let value = make()
            values[key] = value
            return body(value)
        }
    }

    /// The value kept for `key`, without making one.
    func cached(_ key: Key) -> Value? { lock.withLock { values[key] } }

    var count: Int { lock.withLock { values.count } }
}
