import CoreGraphics
import Foundation

/// The frame a window opens with: the saved one when it is usable, else `fallback`, kept at least `minimum` in
/// size and inside the screen it overlaps most. `screens` are the screens' visible frames; `defaultScreen` is used
/// when there are none.
public func restoredWindowFrame(
    _ stored: WindowFrame?, fallback: CGRect, minimum: CGSize, screens: [CGRect], defaultScreen: CGRect
) -> CGRect {
    var candidate = fallback
    if let stored, [stored.x, stored.y, stored.width, stored.height].allSatisfy(\.isFinite), stored.width > 0,
        stored.height > 0
    {
        candidate = CGRect(x: stored.x, y: stored.y, width: stored.width, height: stored.height)
    }
    let screen =
        screens.max { left, right in
            let l = left.intersection(candidate)
            let r = right.intersection(candidate)
            return (l.isNull ? 0 : l.width * l.height) < (r.isNull ? 0 : r.width * r.height)
        } ?? defaultScreen
    candidate.size.width = min(max(candidate.width, minimum.width), screen.width)
    candidate.size.height = min(max(candidate.height, minimum.height), screen.height)
    candidate.origin.x = max(screen.minX, min(candidate.minX, screen.maxX - candidate.width))
    candidate.origin.y = max(screen.minY, min(candidate.minY, screen.maxY - candidate.height))
    return candidate
}
