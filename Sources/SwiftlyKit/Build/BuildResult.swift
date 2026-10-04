import Foundation

/// The verified runnable filesystem result of one successful build.
public struct BuildResult: Sendable {

    /// The final executable to launch.
    public let executable: URL

    public let executableName: String

    /// The exact verified runtime resource bundles required by the executable,
    /// ordered by bundle name.
    public let resourceBundles: [URL]

    let architecture: LinuxArchitecture

}

extension BuildResult {

    /// The directory that contains the executable and its required runtime resource bundles.
    /// Managed build storage can also contain unrelated SwiftPM output.
    public var directory: URL {
        executable.deletingLastPathComponent()
    }

}

extension BuildResult {

    /// Exports the verified executable and its resource bundles without rebuilding.
    /// Returns a new result identifying the exported files; this result remains unchanged.
    /// The parent must exist. By default, the destination must not exist.
    /// Destination policy is enforced when the staged output is committed.
    public func export(
        to destination: URL,
        policy: ExportDestinationPolicy = .createNewDirectory
    ) async throws -> BuildResult {

        try await MutationGate.shared.withAccess {
            do {
                return try await AtomicOutputExporter.export(
                    executable: executable,
                    executableName: executableName,
                    resourceBundles: resourceBundles,
                    architecture: architecture,
                    to: destination,
                    destinationPolicy: policy,
                    prepareExecutable: { stagedExecutable in
                        try ELFExecutableVerifier.verify(stagedExecutable, architecture: architecture)
                    }
                )
            } catch let error as SwiftPMError {
                throw error.swiftlyKitError
            }
        }
    }

}
