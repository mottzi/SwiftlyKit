import Foundation

/// Caller-owned SwiftPM cache, configuration, and security storage.
/// Explicit locations must be absolute local URLs and must not overlap selected scratch storage.
public struct SwiftPMSharedStorage: Sendable {

    let cacheDirectory: URL?
    let configurationDirectory: URL?
    let securityDirectory: URL?

    /// Creates optional explicit locations for SwiftPM shared state.
    ///
    /// A `nil` location preserves SwiftPM's standard behavior. Each explicit
    /// location is validated when a workflow starts.
    public init(
        cacheDirectory: URL? = nil,
        configurationDirectory: URL? = nil,
        securityDirectory: URL? = nil
    ) {
        self.cacheDirectory = cacheDirectory
        self.configurationDirectory = configurationDirectory
        self.securityDirectory = securityDirectory
    }

}

extension SwiftPMSharedStorage {

    /// Validates and canonicalizes each explicit shared-storage location.
    func validated() throws -> Self {
        Self(
            cacheDirectory: try Self.validate(cacheDirectory),
            configurationDirectory: try Self.validate(configurationDirectory),
            securityDirectory: try Self.validate(securityDirectory)
        )
    }

    /// Returns the first shared-storage location that overlaps the scratch directory.
    func overlappingDirectory(with scratchDirectory: URL) -> URL? {
        for directory in [cacheDirectory, configurationDirectory, securityDirectory].compactMap({ $0 }) {
            guard fileURLsOverlap(directory, scratchDirectory) else { continue }
            return directory
        }

        return nil
    }

    /// Returns command-line arguments for each explicit shared-storage location.
    var commandArguments: [String] {
        var arguments: [String] = []

        if let cacheDirectory {
            arguments += ["--cache-path", cacheDirectory.path(percentEncoded: false)]
        }
        if let configurationDirectory {
            arguments += ["--config-path", configurationDirectory.path(percentEncoded: false)]
        }
        if let securityDirectory {
            arguments += ["--security-path", securityDirectory.path(percentEncoded: false)]
        }

        return arguments
    }

}

private extension SwiftPMSharedStorage {

    static func validate(_ directory: URL?) throws -> URL? {
        guard let directory else { return nil }

        let path = directory.path(percentEncoded: false)
        guard directory.isFileURL,
              directory.host == nil,
              directory.query == nil,
              directory.fragment == nil,
              path.hasPrefix("/")
        else { throw SwiftlyKitError.unsafeSwiftPMSharedStorage(directory) }

        do { return try CanonicalFileURL.resolve(directory) }
        catch { throw SwiftlyKitError.unsafeSwiftPMSharedStorage(directory) }
    }

}

extension SwiftPMSharedStorage {

    /// Uses SwiftPM's standard cache, configuration, and security locations.
    public static let standard = Self()

}
