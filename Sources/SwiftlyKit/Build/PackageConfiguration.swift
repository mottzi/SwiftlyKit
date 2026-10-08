import CryptoKit
import Foundation

/// Executable products from the root manifest evaluated with one exact compiler and host SDK.
/// Dependencies have not been resolved or validated. A build validates the complete graph before compilation.
public struct PackageConfiguration: Sendable {

    /// The environment that successfully evaluated the root manifest.
    public let environment: LocalBuildEnvironment

    /// Executable products available for configuration.
    public let products: ExecutableProducts

}

extension SwiftPMScratchStorage {

    /// Stable root-manifest storage independent of builds, resets, and source observation.
    static func configuration(for packageRoot: URL) -> SwiftPMScratchStorage {

        let path = packageRoot.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        let identity = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return .directory(caches.appending(path: "SwiftlyKit/Configuration/" + identity, directoryHint: .isDirectory))
    }

}
