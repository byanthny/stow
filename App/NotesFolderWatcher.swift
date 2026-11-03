import CoreServices
import Foundation

enum NotesFolderWatcherError: Error {
    case invalidDirectory, cannotCreateStream, cannotStartStream
}

/// Watches uncoordinated editors, including atomic file replacements, with one recursive FSEvents stream.
/// The callback runs on a utility queue and must schedule any UI work onto the main actor.
final class NotesFolderWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.stow.notes-file-events", qos: .utility)
    private let lock = NSLock()
    private let context: NotesWatcherContext
    private var stream: FSEventStreamRef?

    init(directory: URL, changed: @escaping @Sendable () -> Void) throws {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw NotesFolderWatcherError.invalidDirectory
        }
        let callbackContext = NotesWatcherContext(changed: changed)
        self.context = callbackContext
        var streamContext = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackContext).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<NotesWatcherContext>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<NotesWatcherContext>.fromOpaque(pointer).release()
            },
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, count, paths, eventFlags, _ in
                    guard let info else { return }
                    let context = Unmanaged<NotesWatcherContext>.fromOpaque(info).takeUnretainedValue()
                    // Without UseCFTypes, FSEvents supplies an array of NUL-terminated paths.
                    let pathPointers = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                    let rescanFlags = FSEventStreamEventFlags(
                        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount
                            | kFSEventStreamEventFlagUnmount)
                    for index in 0..<count {
                        if eventFlags[index] & rescanFlags != 0 {
                            context.notify()
                            return
                        }
                        let path = String(cString: pathPointers[index])
                        if (path as NSString).pathExtension.lowercased() == "md" {
                            context.notify()
                            return
                        }
                    }
                },
                &streamContext,
                [directory.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.15,
                flags)
        else { throw NotesFolderWatcherError.cannotCreateStream }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            callbackContext.deactivate()
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw NotesFolderWatcherError.cannotStartStream
        }
        stream = created
    }

    /// Idempotent; deactivates callbacks before stopping and releasing the stream.
    func stop() {
        lock.lock()
        let current = stream
        stream = nil
        context.deactivate()
        lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }

    deinit { stop() }
}

private final class NotesWatcherContext: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let changed: @Sendable () -> Void

    init(changed: @escaping @Sendable () -> Void) { self.changed = changed }

    func notify() {
        lock.lock()
        let shouldNotify = active
        lock.unlock()
        if shouldNotify { changed() }
    }

    func deactivate() {
        lock.lock()
        active = false
        lock.unlock()
    }
}
