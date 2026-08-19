import Foundation

/// The durable installation namespace used by a SwiftlyKit workflow.
public enum EnvironmentStorage: Sendable, Hashable {

    /// Uses Swiftly and SwiftPM's standard per-user locations.
    case standard

    /// Uses one dedicated caller-owned root for Swiftly state, toolchains, and SDKs.
    /// SwiftlyKit derives its Swiftly home, binary, toolchain, and SwiftPM SDK registry
    /// directories below this root. The root must be absolute and outside package and SwiftPM workflow storage.
    case directory(URL)

}

extension EnvironmentStorage {

    /// Resolves the namespace into deterministic Swiftly directories.
    func resolved(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws(SwiftlyKitError) -> EnvironmentStorageLocation {

        switch self {
            case .standard:
                let home = homeDirectory
                    .appending(path: ".swiftly", directoryHint: .isDirectory)
                    .standardizedFileURL
                return EnvironmentStorageLocation(
                    storage: self,
                    homeDirectory: home,
                    binDirectory: home.appending(path: "bin", directoryHint: .isDirectory),
                    toolchainsDirectory: homeDirectory.appending(
                        path: "Library/Developer/Toolchains",
                        directoryHint: .isDirectory
                    ).standardizedFileURL,
                    swiftPMSDKDirectory: nil
                )

            case .directory(let root):
                let canonicalRoot = try Self.validatedRoot(root)
                let location = EnvironmentStorageLocation(
                    storage: .directory(canonicalRoot),
                    homeDirectory: canonicalRoot,
                    binDirectory: canonicalRoot.appending(path: "bin", directoryHint: .isDirectory),
                    toolchainsDirectory: canonicalRoot.appending(
                        path: "toolchains",
                        directoryHint: .isDirectory
                    ),
                    swiftPMSDKDirectory: canonicalRoot.appending(
                        path: "swift-sdks",
                        directoryHint: .isDirectory
                    )
                )
                try location.validateDerivedPaths()
                return location
        }
    }

    /// Validates a custom namespace against a location that the workflow may mutate.
    func validateNotOverlapping(_ location: URL) throws(SwiftlyKitError) {
        _ = try validated(against: location)
    }

    /// Returns the canonical namespace after validating it against mutable workflow state.
    func validated(against location: URL) throws(SwiftlyKitError) -> Self {
        guard case .directory = self else { return self }
        let resolved = try resolved()
        guard !fileURLsOverlap(resolved.homeDirectory, location) else {
            throw .unsafeEnvironmentStorage(resolved.homeDirectory)
        }
        return .directory(resolved.homeDirectory)
    }

}

extension EnvironmentStorage {

    /// Validates and canonicalizes one custom storage root.
    static func validatedRoot(_ root: URL) throws(SwiftlyKitError) -> URL {

        let path = root.path(percentEncoded: false)
        guard root.isFileURL,
              root.host == nil,
              root.query == nil,
              root.fragment == nil,
              path.hasPrefix("/")
        else { throw .unsafeEnvironmentStorage(root) }

        let canonicalRoot: URL
        do { canonicalRoot = try CanonicalFileURL.resolve(root).standardizedFileURL }
        catch { throw .unsafeEnvironmentStorage(root) }

        guard canonicalRoot.path != "/", !canonicalRoot.pathComponents.isEmpty
        else { throw .unsafeEnvironmentStorage(root) }

        try validateExistingDirectory(canonicalRoot, reporting: root)

        return canonicalRoot
    }

}

/// One validated environment namespace used internally by subprocess commands.
struct EnvironmentStorageLocation: Sendable, Hashable {

    let storage: EnvironmentStorage
    let homeDirectory: URL
    let binDirectory: URL
    let toolchainsDirectory: URL
    let swiftPMSDKDirectory: URL?

    /// The Swiftly directory variables for this namespace.
    var environment: [String: String] {
        [
            "SWIFTLY_HOME_DIR": homeDirectory.path(percentEncoded: false),
            "SWIFTLY_BIN_DIR": binDirectory.path(percentEncoded: false),
            "SWIFTLY_TOOLCHAINS_DIR": toolchainsDirectory.path(percentEncoded: false)
        ]
    }

    /// Inherited process values with Swiftly location variables bound to this namespace.
    var processEnvironment: [String: String] {
        var values = ProcessInfo.processInfo.environment
        for name in values.keys.filter({ $0.hasPrefix("SWIFTLY_") }) {
            values[name] = nil
        }
        for (name, value) in environment {
            values[name] = value
        }
        return values
    }

}

extension EnvironmentStorageLocation {

    /// Rejects existing derived-directory symlinks that escape the selected root.
    func validateDerivedPaths() throws(SwiftlyKitError) {

        guard case .directory = storage else { return }

        let canonicalHome: URL
        do { canonicalHome = try CanonicalFileURL.resolve(homeDirectory) }
        catch { throw .unsafeEnvironmentStorage(homeDirectory) }
        let derivedDirectories = [binDirectory, toolchainsDirectory] + [swiftPMSDKDirectory].compactMap { $0 }
        for derivedDirectory in derivedDirectories {
            try validateExistingDirectory(derivedDirectory, reporting: homeDirectory)

            let canonicalDirectory: URL
            do { canonicalDirectory = try CanonicalFileURL.resolve(derivedDirectory) }
            catch { throw .unsafeEnvironmentStorage(homeDirectory) }

            guard canonicalDirectory.pathComponents.starts(with: canonicalHome.pathComponents)
            else { throw .unsafeEnvironmentStorage(homeDirectory) }
        }
    }

}

private func validateExistingDirectory(
    _ url: URL,
    reporting errorURL: URL
) throws(SwiftlyKitError) {

    let path = url.path(percentEncoded: false)
    let filesystemPath = path == "/" || !path.hasSuffix("/")
        ? path
        : String(path.dropLast())
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
        atPath: filesystemPath,
        isDirectory: &isDirectory
    )
    if exists {
        guard isDirectory.boolValue else { throw .unsafeEnvironmentStorage(errorURL) }
        return
    }

    let attributes = try? FileManager.default.attributesOfItem(
        atPath: filesystemPath
    )
    if (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink {
        throw .unsafeEnvironmentStorage(errorURL)
    }
}
