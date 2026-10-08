import Foundation

/// Canonical source roots and exclusions for one package observation.
/// New scopes resolve the current symbolic-link targets.
/// Snapshots create new scopes. Monitors retain their initial scope.
struct PackageSourceScope: Sendable {

    let roots: [URL]
    private let excludedRoots: [URL]

    init(
        roots: [URL],
        excluding excludedRoots: [URL] = []
    ) throws {
        self.roots = try Self.canonicalURLs(roots)
        self.excludedRoots = try Self.canonicalURLs(excludedRoots)
    }

    /// Returns true for a canonical path within a source root after exclusions.
    /// A deeper source root overrides an enclosing exclusion.
    /// Does not read the filesystem.
    func includes(_ url: URL) -> Bool {
        let rootDepth = deepestContainingRoot(url, in: roots)
        guard rootDepth >= 0 else { return false }
        return rootDepth >= deepestContainingRoot(url, in: excludedRoots)
    }

    /// Whether an event path belongs to relevant source, including top-level
    /// SwiftPM metadata rules for each containing observed root.
    func isRelevantEvent(_ url: URL) -> Bool {
        let exclusionDepth = deepestContainingRoot(url, in: excludedRoots)
        let containingRoots = roots.filter {
            url.pathComponents.starts(with: $0.pathComponents)
                && $0.pathComponents.count >= exclusionDepth
        }

        return containingRoots.contains { root in
            let relativeComponents = url.pathComponents.dropFirst(root.pathComponents.count)
            guard let firstComponent = relativeComponents.first else { return true }
            return !Self.ignoredTopLevelNames.contains(firstComponent)
        }
    }

    /// Keeps outer roots separate from roots that their ignored storage could hide.
    /// Stream count does not grow with the number of dependency checkouts.
    var eventStreamGroups: [EventStreamGroup] {

        let outer = Self.outermostURLs(roots)
        let nested = roots.filter { !outer.contains($0) }
        return [outer, nested].filter { !$0.isEmpty }.map { watchedRoots in
            let candidates = Array(Set(watchedRoots.flatMap(eventExclusions)))
                .filter { candidate in
                    !watchedRoots.contains { $0.pathComponents.starts(with: candidate.pathComponents) }
                }
            let exclusions = Self.outermostURLs(candidates).sorted { first, second in
                if first.pathComponents.count != second.pathComponents.count {
                    return first.pathComponents.count < second.pathComponents.count
                }
                return first.path(percentEncoded: false) < second.path(percentEncoded: false)
            }
            // native streams accept at most eight exclusions, and the callback filters every omitted path
            return EventStreamGroup(watchRoots: watchRoots(for: watchedRoots), exclusions: Array(exclusions.prefix(8)))
        }
    }

    /// A moved or replaced watch ancestor invalidates every semantic root beneath it.
    func containsSourceRoot(beneath url: URL) -> Bool {
        roots.contains { $0.pathComponents.starts(with: url.pathComponents) }
    }

    /// Native exclusion candidates for one root; grouping protects nested roots before applying them.
    func eventExclusions(for root: URL) -> [URL] {

        let candidates = Self.ignoredTopLevelNames.map { root.appending(path: $0) }
            + excludedRoots.filter {
                $0 != root && $0.pathComponents.starts(with: root.pathComponents)
            }
        return Self.outermostURLs(Array(Set(candidates)))
    }

    /// Whether a child at this relative path should be traversed or hashed.
    func includesEntry(named name: String, relativePath: String) -> Bool {
        !relativePath.isEmpty || !Self.ignoredTopLevelNames.contains(name)
    }

}

extension PackageSourceScope {

    /// Coalesces sibling checkouts without changing the semantic roots or inclusion rules.
    /// WatchRoot otherwise allocates ancestor watches repeatedly for every checkout.
    private func watchRoots(for roots: [URL]) -> [URL] {

        let outer = Self.outermostURLs(roots)
        let siblings = Dictionary(grouping: outer) { $0.deletingLastPathComponent().path(percentEncoded: false) }
        let anchors = siblings.flatMap { path, children in
            let parent = URL(filePath: path, directoryHint: .isDirectory)
            let hasObservedAncestor = self.roots.contains { parent.pathComponents.starts(with: $0.pathComponents) }
            return children.count > 1 && hasObservedAncestor ? [parent] : children
        }
        return Self.outermostURLs(anchors).sorted {
            $0.path(percentEncoded: false) < $1.path(percentEncoded: false)
        }
    }

    private func deepestContainingRoot(_ url: URL, in roots: [URL]) -> Int {

        roots.reduce(into: -1) { depth, root in
            guard url.pathComponents.starts(with: root.pathComponents) else { return }
            depth = max(depth, root.pathComponents.count)
        }
    }

}

extension PackageSourceScope {

    private static func outermostURLs(_ urls: [URL]) -> [URL] {

        urls.filter { url in
            !urls.contains { other in
                other != url && url.pathComponents.starts(with: other.pathComponents)
            }
        }
    }

    private static func canonicalURLs(_ urls: [URL]) throws -> [URL] {
        Array(Set(try urls.map(CanonicalFileURL.resolve)))
            .sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

}

extension PackageSourceScope {

    /// Native watch roots and exclusions for one source event stream.
    struct EventStreamGroup: Sendable {
        let watchRoots: [URL]
        let exclusions: [URL]
    }

}

extension PackageSourceScope {

    private static let ignoredTopLevelNames: Set<String> = [".build", ".git", ".swiftpm"]

}
