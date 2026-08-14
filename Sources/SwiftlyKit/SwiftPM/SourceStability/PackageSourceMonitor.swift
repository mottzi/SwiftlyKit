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

    /// Starts one recursive FSEvents stream for the selected package roots.
    static func start(
        roots: [URL],
        excluding excludedRoots: [URL] = []
    ) throws -> PackageSourceMonitor {

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

    /// Locked ownership of one FSEvents stream and its recorded mutation state.
    fileprivate final class Storage: @unchecked Sendable {

        private let roots: [URL]
        private let excludedRoots: [URL]
        private let queue = DispatchQueue(label: "codes.mottzi.SwiftlyKit.PackageSourceMonitor")
        private let lock = NSLock()
        private var stream: FSEventStreamRef?
        private var didChange = false
        private var isReliable = true

        init(roots: [URL], excludedRoots: [URL]) throws {
            self.roots = try Self.canonicalURLs(roots)
            self.excludedRoots = try Self.canonicalURLs(excludedRoots)
        }

        func start() throws {

            guard !roots.isEmpty else { throw Error.streamCreationFailed }

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
            let paths = roots.map { $0.path(percentEncoded: false) }

            guard let stream = FSEventStreamCreate(
                nil,
                packageSourceEventCallback,
                &context,
                paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.05,
                flags
            ) else { throw Error.streamCreationFailed }

            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                throw Error.streamStartFailed
            }

            FSEventStreamFlushSync(stream)
            lock.withLock { self.stream = stream }
        }

        func record(
            path: String,
            flags: FSEventStreamEventFlags
        ) {

            if flags & Self.unreliableEventFlags != 0 {
                lock.withLock { isReliable = false }
                return
            }

            let directoryStructuralFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated
                    | kFSEventStreamEventFlagItemRemoved
                    | kFSEventStreamEventFlagItemRenamed
            )
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0,
               flags & directoryStructuralFlags == 0 {
                return
            }

            let eventURL = URL(filePath: path)
            guard let parent = try? CanonicalFileURL.resolve(eventURL.deletingLastPathComponent()) else {
                lock.withLock { didChange = true }
                return
            }
            let url = parent.appending(path: eventURL.lastPathComponent).standardized
            guard isRelevant(url) else { return }
            lock.withLock { didChange = true }
        }

        func beginObservation() {

            let stream = lock.withLock { self.stream }
            if let stream { FSEventStreamFlushSync(stream) }
            lock.withLock {
                didChange = false
                isReliable = true
            }
        }

        func finish() -> Outcome {

            guard let stream = takeStream() else { return lock.withLock { outcome } }

            FSEventStreamFlushSync(stream)
            stopAndRelease(stream)
            return lock.withLock { outcome }
        }

        func cancel() {
            guard let stream = takeStream() else { return }
            stopAndRelease(stream)
        }

    }

}

extension PackageSourceMonitor.Storage {

    private var outcome: PackageSourceMonitor.Outcome {
        if !isReliable { return .unreliable }
        return didChange ? .changed : .unchanged
    }

    private func takeStream() -> FSEventStreamRef? {
        lock.withLock {
            let stream = self.stream
            self.stream = nil
            return stream
        }
    }

    private func stopAndRelease(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func isRelevant(_ url: URL) -> Bool {

        let exclusionDepth = Self.deepestContainingRoot(url, in: excludedRoots)
        let containingRoots = roots.filter {
            url.pathComponents.starts(with: $0.pathComponents)
                && $0.pathComponents.count >= exclusionDepth
        }

        return containingRoots.contains { root in
            let relativeComponents = url.pathComponents.dropFirst(root.pathComponents.count)
            guard let firstComponent = relativeComponents.first else { return true }
            return !Self.ignoredNames.contains(firstComponent)
        }
    }

    private static func canonicalURLs(_ urls: [URL]) throws -> [URL] {
        Array(Set(try urls.map(CanonicalFileURL.resolve)))
            .sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

    private static func deepestContainingRoot(_ url: URL, in roots: [URL]) -> Int {
        roots.reduce(into: -1) { depth, root in
            guard url.pathComponents.starts(with: root.pathComponents) else { return }
            depth = max(depth, root.pathComponents.count)
        }
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
    }

}

extension PackageSourceMonitor.Storage {

    private static let ignoredNames: Set<String> = [".build", ".git", ".swiftpm"]
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
