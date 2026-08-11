import Foundation

/// Requests Apple's interactive Command Line Tools installer when the host SDK is unavailable.
struct HostCLTRequest {

    private(set) var runner: any SubprocessRunning = LiveSubprocessRunner()

    private(set) var assessHost: @Sendable () async throws -> HostReadiness = {
        try await HostPreflight().assess()
    }

    /// Returns after the request is accepted, not after the user completes installation.
    func request() async throws {

        let readiness: HostReadiness
        do {
            readiness = try await assessHost()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SwiftlyKitError.commandLineToolsInstallationRequestFailed(
                "The host environment could not be checked."
            )
        }

        switch readiness {
            case .ready: return
            case .developerToolsUnavailable: try await requestSystemInstaller()
            case .unsupportedHost: throw SwiftlyKitError.unsupportedHost
        }
    }

}

extension HostCLTRequest {

    private func requestSystemInstaller() async throws {

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

extension HostCLTRequest {

    private static func bounded(_ value: String) -> String {
        String(value.prefix(8 * 1024))
    }

}
