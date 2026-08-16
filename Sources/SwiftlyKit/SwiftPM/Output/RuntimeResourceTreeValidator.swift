import Darwin
import Foundation

/// Trusted-local validation for a runtime resource tree that SwiftlyKit can publish.
enum RuntimeResourceTreeValidator {

    /// Verifies one immediate runtime resource bundle and all entries below it.
    static func validateBundle(_ bundle: URL, in directory: URL) throws {

        let root = bundle.standardizedFileURL
        guard root.deletingLastPathComponent().pathComponents == directory.standardizedFileURL.pathComponents,
              root.pathExtension == "resources"
        else { throw SwiftPMError.runtimeResourceVerificationFailed }

        try validateDirectory(root, containedIn: directory.standardizedFileURL)
    }

    /// Verifies that a path is a regular file, is not a symbolic link, and is below the supplied directory.
    static func validateRegularFile(_ file: URL, containedIn directory: URL) throws {

        let path = file.standardizedFileURL
        try validateContainment(path, in: directory.standardizedFileURL)

        var information = stat()
        guard lstat(path.path(percentEncoded: false), &information) == 0,
              information.st_mode & S_IFMT == S_IFREG
        else { throw SwiftPMError.runtimeResourceVerificationFailed }

        try validatePathComponents(of: path, below: directory.standardizedFileURL)
    }

}

extension RuntimeResourceTreeValidator {

    private static func validateDirectory(_ directory: URL, containedIn root: URL) throws {

        try validateContainment(directory, in: root)

        var information = stat()
        guard lstat(directory.path(percentEncoded: false), &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR
        else { throw SwiftPMError.runtimeResourceVerificationFailed }

        try validatePathComponents(of: directory, below: root)

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for entry in contents {
            var entryInformation = stat()
            guard lstat(entry.path(percentEncoded: false), &entryInformation) == 0
            else { throw SwiftPMError.runtimeResourceVerificationFailed }

            switch entryInformation.st_mode & S_IFMT {
                case S_IFDIR:
                    try validateDirectory(entry.standardizedFileURL, containedIn: root)
                case S_IFREG:
                    guard entryInformation.st_nlink == 1
                    else { throw SwiftPMError.runtimeResourceVerificationFailed }
                default:
                    throw SwiftPMError.runtimeResourceVerificationFailed
            }
        }
    }

    private static func validateContainment(_ url: URL, in directory: URL) throws {
        guard url.pathComponents.starts(with: directory.pathComponents),
              url.pathComponents.count > directory.pathComponents.count
        else { throw SwiftPMError.runtimeResourceVerificationFailed }
    }

    private static func validatePathComponents(of url: URL, below directory: URL) throws {

        var current = url
        while current.pathComponents.count > directory.pathComponents.count {
            var information = stat()
            guard lstat(current.path(percentEncoded: false), &information) == 0,
                  information.st_mode & S_IFMT != S_IFLNK
            else { throw SwiftPMError.runtimeResourceVerificationFailed }
            current.deleteLastPathComponent()
        }
    }

}
