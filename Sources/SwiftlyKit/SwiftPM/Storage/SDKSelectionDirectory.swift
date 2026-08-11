import CryptoKit
import Foundation

/// Resolves one deterministic SwiftPM search directory for an exact Static Linux SDK.
enum SDKSelectionDirectory {

    static func resolve(
        sdkIdentifier: String,
        sdkBundleURL: URL,
        scratchDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {

        guard isValidIdentifier(sdkIdentifier) else { throw Error.invalidIdentifier(sdkIdentifier) }

        let scratchDirectory = scratchDirectory.standardizedFileURL
        do { try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true) }
        catch { throw Error.couldNotCreateDirectory(scratchDirectory.path) }

        let sdkSelectionsDirectory = scratchDirectory
            .appending(path: ".swiftlykit", directoryHint: .isDirectory)
            .appending(path: "sdk-selections", directoryHint: .isDirectory)

        try createOwnedDirectoryHierarchy(
            from: scratchDirectory,
            components: [".swiftlykit", "sdk-selections"],
            fileManager: fileManager
        )

        let canonicalBundleURL = sdkBundleURL.resolvingSymlinksInPath().standardizedFileURL
        let searchDirectory = sdkSelectionsDirectory.appending(
            path: selectionComponent(sdkIdentifier: sdkIdentifier, canonicalBundleURL: canonicalBundleURL),
            directoryHint: .isDirectory
        )
        try createOwnedDirectory(at: searchDirectory, fileManager: fileManager)

        let linkURL = searchDirectory.appending(path: sdkBundleURL.lastPathComponent)
        switch try selectionState(
            in: searchDirectory,
            linkURL: linkURL,
            canonicalBundleURL: canonicalBundleURL,
            fileManager: fileManager
        ) {
            case .ready:
                return searchDirectory
            case .absent:
                return try createSelection(
                    in: searchDirectory,
                    linkURL: linkURL,
                    canonicalBundleURL: canonicalBundleURL,
                    fileManager: fileManager
                )
        }
    }

}

extension SDKSelectionDirectory {

    private static func isValidIdentifier(
        _ identifier: String
    ) -> Bool {
        
        guard !identifier.isEmpty else { return false }
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return identifier.unicodeScalars.allSatisfy(allowedCharacters.contains)
    }

    private static func selectionComponent(
        sdkIdentifier: String,
        canonicalBundleURL: URL
    ) -> String {
        
        let digest = SHA256.hash(data: Data(canonicalBundleURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        return "\(sdkIdentifier)-\(digest)"
    }

}

extension SDKSelectionDirectory {

    private static func createSelection(
        in searchDirectory: URL,
        linkURL: URL,
        canonicalBundleURL: URL,
        fileManager: FileManager
    ) throws -> URL {

        do {
            try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: canonicalBundleURL)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // A separate SwiftlyKit instance or process won the creation race.
            return try requireReadySelection(
                in: searchDirectory,
                linkURL: linkURL,
                canonicalBundleURL: canonicalBundleURL,
                fileManager: fileManager
            )
        } catch {
            throw Error.couldNotCreateSelection(linkURL.path)
        }

        return try requireReadySelection(
            in: searchDirectory,
            linkURL: linkURL,
            canonicalBundleURL: canonicalBundleURL,
            fileManager: fileManager
        )
    }

    private static func requireReadySelection(
        in searchDirectory: URL,
        linkURL: URL,
        canonicalBundleURL: URL,
        fileManager: FileManager
    ) throws -> URL {

        switch try selectionState(
            in: searchDirectory,
            linkURL: linkURL,
            canonicalBundleURL: canonicalBundleURL,
            fileManager: fileManager
        ) {
            case .ready: return searchDirectory
            case .absent: throw Error.couldNotCreateSelection(linkURL.path)
        }
    }

    private static func selectionState(
        in searchDirectory: URL,
        linkURL: URL,
        canonicalBundleURL: URL,
        fileManager: FileManager
    ) throws -> SelectionState {

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: searchDirectory,
                includingPropertiesForKeys: [.isSymbolicLinkKey]
            )
        } catch {
            throw Error.couldNotCreateDirectory(searchDirectory.path)
        }

        guard !entries.isEmpty else { return .absent }
        guard entries.count == 1,
              entries[0].lastPathComponent == linkURL.lastPathComponent else {
            let unexpectedEntry = entries.first { $0.lastPathComponent != linkURL.lastPathComponent }
                ?? entries.first
            throw Error.unexpectedItem(unexpectedEntry?.path ?? searchDirectory.path)
        }

        let destinationURL: URL
        do {
            destinationURL = try URL(
                filePath: fileManager.destinationOfSymbolicLink(atPath: linkURL.path),
                relativeTo: searchDirectory
            )
            .resolvingSymlinksInPath()
            .standardizedFileURL
        } catch {
            throw Error.unexpectedItem(linkURL.path)
        }

        guard destinationURL.path == canonicalBundleURL.path else { throw Error.unexpectedItem(linkURL.path) }

        return .ready
    }

}

extension SDKSelectionDirectory {

    private static func createOwnedDirectoryHierarchy(
        from root: URL,
        components: [String],
        fileManager: FileManager
    ) throws {

        var directory = root
        for component in components {
            directory.append(path: component, directoryHint: .isDirectory)
            try createOwnedDirectory(at: directory, fileManager: fileManager)
        }
    }

    private static func createOwnedDirectory(
        at url: URL,
        fileManager: FileManager
    ) throws {

        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
            catch { throw Error.couldNotCreateDirectory(url.path) }
            guard values.isDirectory == true,
                  values.isSymbolicLink != true
            else { throw Error.unexpectedItem(url.path) }
        } catch {
            throw Error.couldNotCreateDirectory(url.path)
        }
    }

}

extension SDKSelectionDirectory {

    enum Error: Equatable, LocalizedError {

        case couldNotCreateDirectory(String)
        case couldNotCreateSelection(String)
        case invalidIdentifier(String)
        case unexpectedItem(String)

        var errorDescription: String? {
            switch self {
                case .couldNotCreateDirectory(let path): "The exact SDK search directory could not be created at \(path)."
                case .couldNotCreateSelection(let path): "The exact SDK selection link could not be created at \(path)."
                case .invalidIdentifier(let identifier): "The exact SDK identifier is invalid: \(identifier)."
                case .unexpectedItem(let path): "The exact SDK search directory contains an unexpected item at \(path)."
            }
        }

    }

}

extension SDKSelectionDirectory {

    private enum SelectionState {

        case absent
        case ready

    }

}
