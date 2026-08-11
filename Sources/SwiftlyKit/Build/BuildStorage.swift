import Foundation

/// The SwiftPM scratch storage used by a build.
public enum BuildStorage: Sendable, Equatable {
    /// The package's `.build` directory.
    case packageDefault

    /// An explicit SwiftPM scratch directory.
    /// It must not equal or contain the package root.
    case directory(URL)
}

extension BuildStorage {

    func directory(for packageRoot: URL) -> URL {
        switch self {
            case .packageDefault:
                packageRoot.appending(path: ".build", directoryHint: .isDirectory)
            case .directory(let directory):
                directory
        }
    }

    func validatedDirectory(for packageRoot: URL) throws -> URL {
        let directory = directory(for: packageRoot)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let packageRoot = packageRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL

        guard !packageRoot.pathComponents.starts(with: directory.pathComponents)
        else { throw SwiftPMError.unsafeBuildStorage(directory) }

        return directory
    }

    var explicitDirectory: URL? {
        guard case .directory(let directory) = self else { return nil }
        return directory
    }
}
