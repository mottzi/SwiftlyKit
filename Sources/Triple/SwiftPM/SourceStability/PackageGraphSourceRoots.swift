import Foundation

/// Source roots from one resolved SwiftPM dependency graph.
struct PackageGraphSourceRoots: Sendable {

    let urls: [URL]

    init(data: Data) throws {
        let graph = try JSONDecoder().decode(Node.self, from: data)
        var paths: Set<String> = []
        graph.collectPaths(into: &paths)
        guard paths.allSatisfy({ $0.hasPrefix("/") }) else { throw Error.invalidPath }
        urls = paths.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

}

extension PackageGraphSourceRoots {

    private struct Node: Decodable {

        let path: String
        let dependencies: [Node]

        func collectPaths(into paths: inout Set<String>) {
            paths.insert(path)
            for dependency in dependencies {
                dependency.collectPaths(into: &paths)
            }
        }

    }

}

extension PackageGraphSourceRoots {

    private enum Error: Swift.Error {
        case invalidPath
    }

}
