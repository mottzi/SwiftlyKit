import CoreServices
import Foundation

/// Thread-safe recursive filesystem observation for relevant package-root mutations.
final class PackageSourceMonitor: @unchecked Sendable {

    private let storage: Storage

    private init(storage: Storage) {
        self.storage = storage
    }

    deinit {
        cancel()
    }

    /// Starts separate source streams so excluded storage cannot hide nested dependency roots.
    static func start(roots: [URL], excluding excludedRoots: [URL] = []) throws -> PackageSourceMonitor {

        let storage = try Storage(roots: roots, excludedRoots: excludedRoots)
        try storage.start()
        return PackageSourceMonitor(storage: storage)
    }

    /// Discards events that occurred before the initial source snapshot starts.
    func beginObservation() async throws {
        try await Task.sleep(for: .milliseconds(100))
        storage.beginObservation()
    }

    /// Flushes pending events, stops observation, and returns the recorded source state.
    func finish() async throws -> Outcome {
        try await Task.sleep(for: .milliseconds(100))
        return storage.finish()
    }

    /// Stops observation without evaluating the recorded state.
    func cancel() {
        storage.cancel()
    }

}

extension PackageSourceMonitor {

    /// Locked ownership of the source streams and their shared mutation state.
    fileprivate final class Storage: @unchecked Sendable {

        private let scope: PackageSourceScope
        private let queue = DispatchQueue(label: "codes.mottzi.SwiftlyKit.PackageSourceMonitor")
        private let lock = NSLock()
        private var streams: [FSEventStreamRef] = []
        private var didChange = false
        private var isReliable = true

        init(roots: [URL], excludedRoots: [URL]) throws {
            self.scope = try PackageSourceScope(roots: roots, excluding: excludedRoots)
        }

        func start() throws {

            guard !scope.roots.isEmpty else { throw Error.streamCreationFailed }

            do {
                for root in scope.roots {
                    let stream = try startStream(for: root)
                    lock.withLock { streams.append(stream) }
                }
            } catch {
                cancel()
                throw error
            }
        }

        func record(path: String, flags: FSEventStreamEventFlags) {

            if flags & Self.unreliableEventFlags != 0 {
                lock.withLock { isReliable = false }
                return
            }

            if Self.isCloneOnlyEvent(flags) { return }

            let directoryStructuralFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated
                    | kFSEventStreamEventFlagItemRemoved
                    | kFSEventStreamEventFlagItemRenamed
            )
            let cloned = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCloned)
            if flags & cloned == 0,
               flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0,
               flags & directoryStructuralFlags == 0 {
                return
            }

            let eventURL = URL(filePath: path)
            guard let parent = try? CanonicalFileURL.resolve(eventURL.deletingLastPathComponent()) else {
                lock.withLock { didChange = true }
                return
            }
            let url = parent.appending(path: eventURL.lastPathComponent).standardized
            guard scope.isRelevantEvent(url) else { return }
            lock.withLock { didChange = true }
        }

        func beginObservation() {

            let streams = lock.withLock { self.streams }
            for stream in streams { FSEventStreamFlushSync(stream) }
            lock.withLock {
                didChange = false
                isReliable = true
            }
        }

        func finish() -> Outcome {

            for stream in takeStreams() {
                FSEventStreamFlushSync(stream)
                stopAndRelease(stream)
            }
            return lock.withLock { outcome }
        }

        func cancel() {
            for stream in takeStreams() { stopAndRelease(stream) }
        }

    }

}

extension PackageSourceMonitor.Storage {

    private func startStream(for root: URL) throws -> FSEventStreamRef {

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        let paths = [root.path(percentEncoded: false)]

        guard let stream = FSEventStreamCreate(
            nil,
            packageSourceEventCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            flags
        ) else { throw PackageSourceMonitor.Error.streamCreationFailed }

        let exclusions = scope.eventExclusions(for: root).map { $0.path(percentEncoded: false) }
        guard FSEventStreamSetExclusionPaths(stream, exclusions as CFArray) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw PackageSourceMonitor.Error.streamExclusionFailed
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw PackageSourceMonitor.Error.streamStartFailed
        }

        FSEventStreamFlushSync(stream)
        return stream
    }

    private func takeStreams() -> [FSEventStreamRef] {
        lock.withLock {
            let streams = self.streams
            self.streams = []
            return streams
        }
    }

    private func stopAndRelease(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private var outcome: PackageSourceMonitor.Outcome {
        if !isReliable { return .unreliable }
        return didChange ? .changed : .unchanged
    }

}

extension PackageSourceMonitor.Storage {

    private static func isCloneOnlyEvent(_ flags: FSEventStreamEventFlags) -> Bool {

        let cloned = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCloned)
        let typeFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemIsDir
                | kFSEventStreamEventFlagItemIsFile
                | kFSEventStreamEventFlagItemIsSymlink
        )

        return flags & cloned != 0 && flags & ~(cloned | typeFlags) == 0
    }

}

extension PackageSourceMonitor {

    /// Final state from recursive package-source observation.
    enum Outcome {
        case changed
        case unchanged
        case unreliable
    }

}

extension PackageSourceMonitor {

    enum Error: Swift.Error, Equatable {
        case streamCreationFailed
        case streamStartFailed
        case streamExclusionFailed
    }

}

extension PackageSourceMonitor.Storage {

    private static let unreliableEventFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
    )

}

private let packageSourceEventCallback: FSEventStreamCallback = {
    _, context, eventCount, eventPaths, eventFlags, _ in

    guard eventCount > 0, let context else { return }

    let storage = Unmanaged<PackageSourceMonitor.Storage>
        .fromOpaque(context)
        .takeUnretainedValue()
    let paths = eventPaths.bindMemory(
        to: UnsafePointer<CChar>?.self,
        capacity: eventCount
    )

    for index in 0..<eventCount {
        guard let path = paths[index] else { continue }
        storage.record(
            path: String(cString: path),
            flags: eventFlags[index]
        )
    }
}
