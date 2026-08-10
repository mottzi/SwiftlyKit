import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Command Line Tools installation requester")
struct CommandLineToolsInstallationRequesterTests {

    @Test("A ready host performs no installation request")
    func readyHostIsNoOp() async throws {

        let commands = RecordingSubprocessRunner(results: [])
        let requester = CommandLineToolsInstallationRequester(
            runner: commands,
            checkHost: {}
        )

        try await requester.request()

        #expect(await commands.commands.isEmpty)
    }

    @Test("An unavailable SDK requests Apple's interactive installer")
    func requestsInstaller() async throws {

        let commands = RecordingSubprocessRunner(results: [.success()])
        let requester = CommandLineToolsInstallationRequester(
            runner: commands,
            checkHost: { throw SwiftlyKitError.developerToolsUnavailable }
        )

        try await requester.request()

        let recorded = await commands.commands
        #expect(recorded == [SubprocessCommand(
            executableURL: URL(filePath: "/usr/bin/xcode-select"),
            arguments: ["--install"]
        )])
    }

    @Test("Unsupported hosts do not request the installer")
    func unsupportedHostIsPreserved() async throws {

        let commands = RecordingSubprocessRunner(results: [])
        let requester = CommandLineToolsInstallationRequester(
            runner: commands,
            checkHost: { throw SwiftlyKitError.unsupportedHost }
        )

        await #expect(throws: SwiftlyKitError.unsupportedHost) {
            try await requester.request()
        }
        #expect(await commands.commands.isEmpty)
    }

    @Test("A rejected installer request reports bounded diagnostics")
    func rejectedRequest() async throws {

        let output = String(repeating: "x", count: 9 * 1024)
        let commands = RecordingSubprocessRunner(results: [.failure(standardError: output)])
        let requester = CommandLineToolsInstallationRequester(
            runner: commands,
            checkHost: { throw SwiftlyKitError.developerToolsUnavailable }
        )

        await #expect(throws: SwiftlyKitError.commandLineToolsInstallationRequestFailed(
            String(repeating: "x", count: 8 * 1024)
        )) {
            try await requester.request()
        }
    }

    @Test("Cancellation while checking the host is preserved")
    func checkCancellationIsPreserved() async throws {

        let requester = CommandLineToolsInstallationRequester(
            runner: RecordingSubprocessRunner(results: []),
            checkHost: { throw CancellationError() }
        )

        await #expect(throws: CancellationError.self) {
            try await requester.request()
        }
    }

    @Test("Cancellation while requesting installation is preserved")
    func requestCancellationIsPreserved() async throws {

        let requester = CommandLineToolsInstallationRequester(
            runner: ThrowingCommandLineToolsRunner(error: CancellationError()),
            checkHost: { throw SwiftlyKitError.developerToolsUnavailable }
        )

        await #expect(throws: CancellationError.self) {
            try await requester.request()
        }
    }

}

private struct ThrowingCommandLineToolsRunner: SubprocessRunning {

    let error: any Error & Sendable

    func run(
        _ command: SubprocessCommand,
        onOutput: SubprocessOutputHandler?
    ) async throws -> SubprocessResult {
        throw error
    }

}
