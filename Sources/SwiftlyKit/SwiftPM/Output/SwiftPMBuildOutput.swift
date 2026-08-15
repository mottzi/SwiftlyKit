import Darwin
import Foundation

/// A selected executable and its exact verified linked runtime resource bundles in SwiftPM build storage.
struct SwiftPMBuildOutput {

    let executable: URL
    let resourceBundles: [URL]

    /// Finds the selected executable and verifies its exact linked resources in a SwiftPM binary directory.
    ///
    /// The method does not read private SwiftPM link metadata when the directory has no `.resources` candidates.
    static func inspect(product: String, in binaryDirectory: URL) throws -> SwiftPMBuildOutput {

        let directory = binaryDirectory.standardizedFileURL
        let executable = directory.appending(path: product)
        let candidates = try resourceCandidates(in: directory)

        guard !candidates.isEmpty else {
            return SwiftPMBuildOutput(executable: executable, resourceBundles: [])
        }

        let linkFile = directory
            .appending(path: "\(product).product", directoryHint: .isDirectory)
            .appending(path: "Objects.LinkFileList")
        try RuntimeResourceTreeValidator.validateRegularFile(linkFile, containedIn: directory)

        let linkedAccessors = try accessorSources(linkedBy: linkFile, in: directory)

        var names = Set<String>()
        for accessor in linkedAccessors {
            let name = try bundleName(in: accessor, binaryDirectory: directory)
            guard names.insert(name).inserted else { throw SwiftPMError.runtimeResourceVerificationFailed }
        }

        let bundles = try names.sorted().map { name in
            guard let bundle = candidates[name] else { throw SwiftPMError.runtimeResourceVerificationFailed }
            try RuntimeResourceTreeValidator.validateBundle(bundle, in: directory)
            return bundle
        }

        return SwiftPMBuildOutput(executable: executable, resourceBundles: bundles)
    }

}

extension SwiftPMBuildOutput {

    private static func resourceCandidates(in directory: URL) throws -> [String: URL] {

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var candidates: [String: URL] = [:]

        for url in contents where url.pathExtension == "resources" {
            guard candidates.updateValue(url.standardizedFileURL, forKey: url.lastPathComponent) == nil
            else { throw SwiftPMError.runtimeResourceVerificationFailed }
        }

        return candidates
    }

    private static func accessorSources(linkedBy linkFile: URL, in directory: URL) throws -> [URL] {

        let contents: String
        do { contents = try String(contentsOf: linkFile, encoding: .utf8) }
        catch { throw SwiftPMError.runtimeResourceVerificationFailed }

        let lines = contents.split(whereSeparator: \Character.isNewline)
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw SwiftPMError.runtimeResourceVerificationFailed }

        var accessors = Set<URL>()
        for line in lines {
            let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard URL(filePath: path).lastPathComponent == "resource_bundle_accessor.swift.o" else { continue }

            let object = URL(filePath: path).standardizedFileURL
            try RuntimeResourceTreeValidator.validateRegularFile(object, containedIn: directory)

            let buildDirectory = object.deletingLastPathComponent()
            guard buildDirectory.pathExtension == "build",
                  buildDirectory.deletingLastPathComponent().pathComponents == directory.pathComponents
            else { throw SwiftPMError.runtimeResourceVerificationFailed }

            let accessor = buildDirectory
                .appending(path: "DerivedSources", directoryHint: .isDirectory)
                .appending(path: "resource_bundle_accessor.swift")
            try RuntimeResourceTreeValidator.validateRegularFile(accessor, containedIn: directory)
            guard accessors.insert(accessor).inserted
            else { throw SwiftPMError.runtimeResourceVerificationFailed }
        }

        return accessors.sorted { lhs, rhs in
            lhs.path(percentEncoded: false) < rhs.path(percentEncoded: false)
        }
    }

    private static func bundleName(in accessor: URL, binaryDirectory: URL) throws -> String {

        let source: String
        do { source = try String(contentsOf: accessor, encoding: .utf8) }
        catch { throw SwiftPMError.runtimeResourceVerificationFailed }

        let expression = try NSRegularExpression(pattern: #"\"([^\"\n\r\\]*\.resources)\""#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let values = expression.matches(in: source, range: range).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        }
        guard !values.isEmpty else { throw SwiftPMError.runtimeResourceVerificationFailed }

        var names = Set<String>()
        var hasAbsolutePath = false
        var hasRelativeName = false
        for value in values {
            let url = URL(filePath: value)
            let name = url.lastPathComponent
            guard url.pathExtension == "resources",
                  !name.isEmpty
            else { throw SwiftPMError.runtimeResourceVerificationFailed }

            if value.hasPrefix("/") {
                guard url.standardizedFileURL
                    .deletingLastPathComponent()
                    .pathComponents == binaryDirectory.pathComponents
                else { throw SwiftPMError.runtimeResourceVerificationFailed }
                hasAbsolutePath = true
            } else {
                guard value == name else { throw SwiftPMError.runtimeResourceVerificationFailed }
                hasRelativeName = true
            }

            names.insert(name)
        }

        guard hasAbsolutePath,
              hasRelativeName,
              names.count == 1,
              let name = names.first
        else { throw SwiftPMError.runtimeResourceVerificationFailed }

        return name
    }

}

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
