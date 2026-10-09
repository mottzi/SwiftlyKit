import CryptoKit
import Foundation

/// Manifest cache identity for one installed compiler and host SDK context.
enum HostManifestCache {

    static let environmentKey = "TRIPLE_HOST_CACHE_CONTEXT"

    /// Returns no identity if the installed compiler context cannot be inspected.
    static func context(for environment: LocalBuildEnvironment) -> String? {

        guard let sdk = environment.hostSDK else { return nil }
        guard let location = try? environment.environmentStorage.resolved() else { return nil }
        let toolchain = location.toolchainsDirectory.appending(path: "swift-\(environment.swiftVersion)-RELEASE.xctoolchain")
        let files = ["usr/bin/swift-frontend", "usr/bin/swift-driver", "usr/bin/swift-package",
                     "usr/lib/swift/pm/ManifestAPI/libPackageDescription.dylib"]
        var identity = "v1\n\(sdk.cacheIdentity)\n\(environment.swiftVersion)"

        for file in files {
            let url = toolchain.appending(path: file).resolvingSymlinksInPath()
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            else { return nil }
            guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
            identity += "\n\(url.path(percentEncoded: false))"
            guard let modified = attributes[.modificationDate] as? Date else { return nil }
            identity += "\n\(modified.timeIntervalSince1970)"
            for key in [FileAttributeKey.systemNumber, .systemFileNumber, .size] {
                identity += "\n\(String(describing: attributes[key]))"
            }
        }

        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

}
