import Foundation

/// Requests Apple's interactive Command Line Tools installer when the host SDK is unavailable.
struct CommandLineToolsInstallationRequester: Sendable {

    private(set) var runner: any SubprocessRunning = LiveSubprocessRunner()

    private(set) var checkHost: @Sendable () async throws -> Void = {
        try await HostPreflight().check()
    }

    /// Returns after the request is accepted, not after the user completes installation.
    func request() async throws {

        do {
            try await checkHost()
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch SwiftlyKitError.developerToolsUnavailable {
            // The explicit recovery operation is needed.
        } catch let error as SwiftlyKitError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SwiftlyKitError.commandLineToolsInstallationRequestFailed(
                "The host environment could not be checked."
            )
        }

        try Task.checkCancellation()

        let command = SubprocessCommand(
            executableURL: URL(filePath: "/usr/bin/xcode-select"),
            arguments: ["--install"]
        )

        let result: SubprocessResult
        do {
            result = try await runner.run(command)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SwiftlyKitError.commandLineToolsInstallationRequestFailed(
                "The system installer request could not be launched."
            )
        }

        try Task.checkCancellation()

        guard result.succeeded else {
            let detail = Self.bounded(result.combinedOutput)
            throw SwiftlyKitError.commandLineToolsInstallationRequestFailed(
                detail.isEmpty ? "The system installer did not accept the request." : detail
            )
        }
    }

}

extension CommandLineToolsInstallationRequester {

    private static func bounded(_ value: String) -> String {
        String(value.prefix(8 * 1024))
    }

}
