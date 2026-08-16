import CryptoKit
import Foundation

/// Deterministic evidence for the files that can affect one SwiftPM package graph.
struct PackageSourceSnapshot: Equatable, Sendable {

    private let digest: [UInt8]
    private let fileCount: Int

    /// Captures paths, contents, permissions, and safe symbolic-link destinations across the selected roots.
    static func capture(
        roots: [URL],
        excluding excludedRoots: [URL] = []
    ) throws -> PackageSourceSnapshot {

        try Task.checkCancellation()
        let scope = try PackageSourceScope(roots: roots, excluding: excludedRoots)
        var hasher = SHA256()
        var fileCount = 0
        var totalByteCount = Int64(0)

        guard !scope.roots.isEmpty else { throw Error.missingRoot }

        for (rootIndex, root) in scope.roots.enumerated() {
            guard isDirectory(root) else { throw Error.unreadableEntry(root) }

            try hashDirectory(
                root,
                relativePath: "",
                rootIndex: rootIndex,
                scope: scope,
                hasher: &hasher,
                fileCount: &fileCount,
                totalByteCount: &totalByteCount
            )
        }

        return PackageSourceSnapshot(
            digest: Array(hasher.finalize()),
            fileCount: fileCount
        )
    }

}

extension PackageSourceSnapshot {

    private static func hashDirectory(
        _ directory: URL,
        relativePath: String,
        rootIndex: Int,
        scope: PackageSourceScope,
        hasher: inout SHA256,
        fileCount: inout Int,
        totalByteCount: inout Int64
    ) throws {

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        let childNames = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).map(\.lastPathComponent).sorted()

        for name in childNames {
            try Task.checkCancellation()
            guard scope.includesEntry(named: name, relativePath: relativePath) else {
                continue
            }
            let child = directory.appending(path: name)
            guard scope.includes(child) else { continue }

            let path = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            let values = try child.resourceValues(forKeys: keys)

            if values.isSymbolicLink == true {
                try hashSymbolicLink(
                    child,
                    relativePath: path,
                    rootIndex: rootIndex,
                    scope: scope,
                    hasher: &hasher
                )
            } else if values.isDirectory == true {
                try hashDirectory(
                    child,
                    relativePath: path,
                    rootIndex: rootIndex,
                    scope: scope,
                    hasher: &hasher,
                    fileCount: &fileCount,
                    totalByteCount: &totalByteCount
                )
                continue
            } else if values.isRegularFile == true {
                try hashRegularFile(
                    child,
                    relativePath: path,
                    rootIndex: rootIndex,
                    hasher: &hasher,
                    totalByteCount: &totalByteCount
                )
            } else {
                throw Error.unsupportedEntry(child)
            }

            fileCount += 1
            guard fileCount <= maximumFileCount else { throw Error.sourceTooLarge }
        }
    }

    private static func hashRegularFile(
        _ file: URL,
        relativePath: String,
        rootIndex: Int,
        hasher: inout SHA256,
        totalByteCount: inout Int64
    ) throws {

        let path = file.path(percentEncoded: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
              byteCount >= 0
        else { throw Error.unsupportedEntry(file) }

        let (newTotalByteCount, overflow) = totalByteCount.addingReportingOverflow(byteCount)
        guard !overflow,
              newTotalByteCount <= maximumTotalByteCount
        else { throw Error.sourceTooLarge }
        totalByteCount = newTotalByteCount

        hasher.update(data: Data("f\(rootIndex):\(relativePath)\0m\(permissions)\0s\(byteCount)\0".utf8))

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var readByteCount = Int64(0)

        while let data = try handle.read(upToCount: readChunkByteCount), !data.isEmpty {
            try Task.checkCancellation()
            readByteCount += Int64(data.count)
            guard readByteCount <= byteCount else { throw Error.unstableEntry(file) }
            hasher.update(data: data)
        }

        guard readByteCount == byteCount else { throw Error.unstableEntry(file) }
        hasher.update(data: Data([0]))
    }

    private static func hashSymbolicLink(
        _ link: URL,
        relativePath: String,
        rootIndex: Int,
        scope: PackageSourceScope,
        hasher: inout SHA256
    ) throws {

        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: link.path(percentEncoded: false)
        )
        let destinationURL = URL(filePath: destination)
        let resolved = if destination.hasPrefix("/") {
            try CanonicalFileURL.resolve(destinationURL)
        } else {
            try CanonicalFileURL.resolve(
                link.deletingLastPathComponent().appending(path: destination)
            )
        }
        let exists = FileManager.default.fileExists(atPath: resolved.path(percentEncoded: false))

        guard exists,
              scope.includes(resolved)
        else { throw Error.escapingSymbolicLink(link) }

        hasher.update(data: Data("l\(rootIndex):\(relativePath)\0".utf8))
        hasher.update(data: Data(destination.utf8))
        hasher.update(data: Data([0]))
    }

}

extension PackageSourceSnapshot {

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false),
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

}

extension PackageSourceSnapshot {

    enum Error: Swift.Error, Equatable {
        case escapingSymbolicLink(URL)
        case missingRoot
        case sourceTooLarge
        case unreadableEntry(URL)
        case unstableEntry(URL)
        case unsupportedEntry(URL)
    }

    private static let maximumFileCount = 200_000
    private static let maximumTotalByteCount = Int64(8 * 1_024 * 1_024 * 1_024)
    private static let readChunkByteCount = 1_048_576

}
