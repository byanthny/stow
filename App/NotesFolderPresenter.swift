import Foundation

/// Foundation coordinates cooperating editors; all callbacks only schedule an app-side reload.
final class NotesFolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let changed: @Sendable () -> Void

    init(directory: URL, changed: @escaping @Sendable () -> Void) {
        presentedItemURL = directory
        self.changed = changed
        let queue = OperationQueue()
        queue.name = "Stow Markdown changes"
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        super.init()
    }

    func presentedItemDidChange() { changed() }
    func presentedSubitemDidAppear(at url: URL) { notify(url) }
    func presentedSubitemDidChange(at url: URL) { notify(url) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        notify(oldURL)
        notify(newURL)
    }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
        notify(url)
    }
    private func notify(_ url: URL) {
        if url.pathExtension.lowercased() == "md" { changed() }
    }
}
