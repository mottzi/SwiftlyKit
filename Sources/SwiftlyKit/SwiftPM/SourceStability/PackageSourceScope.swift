import Foundation

/// Canonical roots and inclusion rules for one package-source observation.
///
/// A scope is intentionally cheap to recreate. Callers that observe a package
/// for a period of time can retain the scope used to start their monitor, while
/// snapshot captures should create a fresh scope so that changing symlinked
/// roots are resolved again.
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

    /// Whether a canonical path is inside an observed root after exclusions.
    ///
    /// A more deeply nested observed root takes precedence over an exclusion,
    /// which allows resolved dependency roots under package scratch storage to
    /// remain observable.
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

    /// Whether a child at this relative path should be traversed or hashed.
    func includesEntry(named name: String, relativePath: String) -> Bool {
        !relativePath.isEmpty || !Self.ignoredTopLevelNames.contains(name)
    }

}

extension PackageSourceScope {

    private func deepestContainingRoot(_ url: URL, in roots: [URL]) -> Int {

        roots.reduce(into: -1) { depth, root in
            guard url.pathComponents.starts(with: root.pathComponents) else { return }
            depth = max(depth, root.pathComponents.count)
        }
    }

}

extension PackageSourceScope {

    private static func canonicalURLs(_ urls: [URL]) throws -> [URL] {
        Array(Set(try urls.map(CanonicalFileURL.resolve)))
            .sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

    private static let ignoredTopLevelNames: Set<String> = [".build", ".git", ".swiftpm"]

}
