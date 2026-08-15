import Foundation

/// The verified runnable filesystem result of one successful build.
public struct BuildResult: Sendable {

    /// The final executable to launch.
    public let executable: URL

    /// The exact verified runtime resource bundles required by the executable,
    /// ordered by bundle name.
    public let resourceBundles: [URL]

}

extension BuildResult {

    /// The directory that contains the executable and its required runtime resource bundles.
    /// Managed build storage can also contain unrelated SwiftPM output.
    public var directory: URL {
        executable.deletingLastPathComponent()
    }

}
