import Foundation

/// Returns `true` when two canonical path locations overlap in either direction.
/// The component comparison avoids treating `/tmp/building` as inside `/tmp/build`.
func fileURLsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {

    let left = comparablePathComponents(lhs)
    let right = comparablePathComponents(rhs)

    return left.contains { leftPath in
        right.contains { rightPath in
            leftPath.starts(with: rightPath) || rightPath.starts(with: leftPath)
        }
    }
}

private func comparablePathComponents(_ url: URL) -> [[String]] {

    var paths = [url.standardizedFileURL.pathComponents]
    paths.append(url.resolvingSymlinksInPath().standardizedFileURL.pathComponents)
    if let canonical = try? CanonicalFileURL.resolve(url) {
        paths.append(canonical.standardizedFileURL.pathComponents)
    }

    return paths.reduce(into: []) { result, path in
        if !result.contains(path) { result.append(path) }
    }
}
