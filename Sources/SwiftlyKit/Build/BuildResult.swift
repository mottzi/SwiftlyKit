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

    /// Coordinates publication and revalidates the executable before it publishes the runnable directory.
    /// The parent must exist. The destination must not exist unless replacement is enabled.
    public func publish(to destination: URL, replacingExisting: Bool = false) async throws -> BuildResult {

        try await publish(
            to: destination,
            destinationPolicy: replacingExisting ? .replace : .create
        )
    }

    /// Coordinates publication into an existing empty directory and revalidates the executable.
    public func publish(into destination: URL) async throws -> BuildResult {
        try await publish(to: destination, destinationPolicy: .existingEmptyDirectory)
    }

}

extension BuildResult {

    /// The directory that contains the executable and its required runtime resource bundles.
    /// Managed build storage can also contain unrelated SwiftPM output.
    public var directory: URL {
        executable.deletingLastPathComponent()
    }

}

extension BuildResult {

    private func publish(
        to destination: URL,
        destinationPolicy: AtomicOutputPublisher.DestinationPolicy
    ) async throws -> BuildResult {

        try await MutationGate.shared.withAccess {
            do {
                return try await AtomicOutputPublisher.publish(
                    executable: executable,
                    executableName: executableName,
                    resourceBundles: resourceBundles,
                    architecture: architecture,
                    to: destination,
                    destinationPolicy: destinationPolicy,
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
