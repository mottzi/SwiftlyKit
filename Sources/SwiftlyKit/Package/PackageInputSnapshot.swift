import Foundation

/// Byte-for-byte package inputs that authorize environment preparation.
struct PackageInputSnapshot: Equatable, Sendable {

    let packageRoot: URL
    let toolsVersion: SwiftVersion
    let swiftVersion: String?

    private let manifest: Data
    private let swiftVersionFileURL: URL?
    private let swiftVersionFile: Data?

    func validateCurrent() throws(SwiftlyKitError) {

        guard let current = try? Self.capture(at: packageRoot), current == self
        else { throw .staleAssessment }
    }

}

extension PackageInputSnapshot {

    /// Validates and captures the inputs needed to select a toolchain.
    static func capture(at packageRoot: URL) throws(SwiftlyKitError) -> PackageInputSnapshot {

        guard packageRoot.isFileURL else { throw .invalidPackageRoot(packageRoot) }

        let canonicalRoot = packageRoot.resolvingSymlinksInPath().standardizedFileURL

        guard isDirectory(at: canonicalRoot) else { throw .invalidPackageRoot(packageRoot) }

        let manifestURL = canonicalRoot.appending(path: "Package.swift")

        guard FileManager.default.fileExists(atPath: manifestURL.path)
        else { throw .invalidPackageRoot(packageRoot) }

        guard isRegularReadableFile(at: manifestURL)
        else { throw .invalidPackageRoot(manifestURL.deletingLastPathComponent()) }

        let manifest: Data
        do { manifest = try Data(contentsOf: manifestURL) }
        catch { throw .invalidPackageRoot(manifestURL.deletingLastPathComponent()) }

        guard let manifestText = String(data: manifest, encoding: .utf8)
        else { throw .invalidPackageRoot(manifestURL.deletingLastPathComponent()) }

        let toolsVersion = try parseToolsVersion(from: manifestText)
        let swiftVersionInput = try nearestSwiftVersionFile(startingAt: canonicalRoot)

        return PackageInputSnapshot(
            packageRoot: canonicalRoot,
            toolsVersion: toolsVersion,
            swiftVersion: swiftVersionInput?.value,
            manifest: manifest,
            swiftVersionFileURL: swiftVersionInput?.url,
            swiftVersionFile: swiftVersionInput?.data
        )
    }

    private static func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isRegularReadableFile(at url: URL) -> Bool {

        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        guard let type = attributes[.type] as? FileAttributeType else { return false }
        guard type == .typeRegular else { return false }

        return FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func parseToolsVersion(from manifest: String) throws(SwiftlyKitError) -> SwiftVersion {

        var hasEarlierNonWhitespaceLine = false

        for line in manifest.split(whereSeparator: \.isNewline) {
            if line.allSatisfy({ $0.isWhitespace && !$0.isNewline }) { continue }

            if let toolsVersion = parseToolsVersionDirective(in: line) {
                if hasEarlierNonWhitespaceLine, toolsVersion < SwiftVersion(major: 6, minor: 0, patch: 0) {
                    throw .unsupportedToolsVersion(toolsVersion)
                }
                return toolsVersion
            }

            hasEarlierNonWhitespaceLine = true
        }

        throw .malformedToolsVersion
    }

    private static func parseToolsVersionDirective(in line: Substring) -> SwiftVersion? {

        let leadingTrimmed = line.drop(while: isHorizontalWhitespace)

        guard leadingTrimmed.hasPrefix("//") else { return nil }

        let label = "swift-tools-version:"
        let afterCommentMarker = leadingTrimmed.dropFirst(2)
        let labelStart = afterCommentMarker.drop(while: isHorizontalWhitespace)

        guard labelStart.count >= label.count else { return nil }
        guard labelStart.prefix(label.count).lowercased() == label else { return nil }

        let valueStart = labelStart.dropFirst(label.count)

        let valueBeforeTerminator: Substring
        if let semicolon = valueStart.firstIndex(of: ";") {
            valueBeforeTerminator = valueStart[..<semicolon]
        } else {
            valueBeforeTerminator = valueStart
        }

        let value = valueBeforeTerminator
            .drop(while: isHorizontalWhitespace)
            .reversed()
            .drop(while: isHorizontalWhitespace)
            .reversed()

        return SwiftVersion(parsing: String(value))
    }

    private static func isHorizontalWhitespace(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }

    private static func nearestSwiftVersionFile(
        startingAt packageRoot: URL
    ) throws(SwiftlyKitError) -> (value: String, url: URL, data: Data)? {

        var directory = packageRoot

        while true {
            let candidate = directory.appending(path: ".swift-version")

            if FileManager.default.fileExists(atPath: candidate.path) {
                let canonicalCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL

                guard isRegularReadableFile(at: canonicalCandidate)
                else { throw .staleAssessment }

                let data: Data
                do { data = try Data(contentsOf: canonicalCandidate) }
                catch { throw .staleAssessment }

                guard let value = String(data: data, encoding: .utf8)
                else { throw .staleAssessment }

                return (
                    value.trimmingCharacters(in: .whitespacesAndNewlines),
                    canonicalCandidate,
                    data
                )
            }

            let parent = directory.deletingLastPathComponent().standardizedFileURL
            guard parent.path != directory.path else { break }

            directory = parent
        }

        return nil
    }

}
