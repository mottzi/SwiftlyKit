import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Installed environment inspector")
struct InstalledEnvironmentInspectorTests {

    @Test("Lists stable toolchains and SDKs through the exact selected toolchain")
    func exactInspection() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"), version: "1.0.0")
        let recorder = CommandRecorder(results: [
            EnvironmentCommandResult(
                succeeded: true,
                standardOutput: """
                    {"toolchains":[
                        {"version":{"name":"6.2.1","type":"stable"}},
                        {"version":{"name":"main-snapshot","type":"snapshot"}}
                    ]}
                    """,
                standardError: ""
            ),
            EnvironmentCommandResult(
                succeeded: true,
                standardOutput: "swift-6.2.1-RELEASE_static-linux-0.0.1\n",
                standardError: ""
            )
        ])

        let state = try await InstalledEnvironmentInspector(
            run: { try await recorder.run($0) },
            isToolchainUsable: { _ in true }
        ).inspect(
            swiftly: swiftly,
            selectedToolchain: SwiftVersion(major: 6, minor: 2, patch: 1)
        )

        #expect(state.toolchainVersions == [SwiftVersion(major: 6, minor: 2, patch: 1)])
        #expect(state.sdkIdentifiers == ["swift-6.2.1-RELEASE_static-linux-0.0.1"])
        let commands = await recorder.commands
        #expect(commands[0].arguments == ["list", "--format", "json"])
        #expect(commands[1].arguments == ["run", "swift", "sdk", "list", "+6.2.1"])

    }

    @Test("Does not ask SwiftPM for SDKs when the exact toolchain is absent")
    func absentToolchainSkipsSDKProbe() async throws {

        let recorder = CommandRecorder(results: [
            EnvironmentCommandResult(succeeded: true, standardOutput: #"{"toolchains":[]}"#, standardError: "")
        ])
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"), version: "1.0.0")

        let state = try await InstalledEnvironmentInspector(
            run: { try await recorder.run($0) },
            isToolchainUsable: { _ in true }
        ).inspect(
            swiftly: swiftly,
            selectedToolchain: SwiftVersion(major: 6, minor: 2, patch: 1)
        )

        #expect(state.sdkIdentifiers.isEmpty)
        #expect(await recorder.commands.count == 1)

    }
    
    @Test("Registry entries without an executable toolchain are unavailable")
    func staleRegistryEntry() async throws {
        
        let recorder = CommandRecorder(results: [
            EnvironmentCommandResult(
                succeeded: true,
                standardOutput: #"{"toolchains":[{"version":{"name":"6.2.1","type":"stable"}}]}"#,
                standardError: ""
            )
        ])
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"), version: "1.0.0")
        let state = try await InstalledEnvironmentInspector(
            run: { try await recorder.run($0) },
            isToolchainUsable: { _ in false }
        ).inspect(
            swiftly: swiftly,
            selectedToolchain: SwiftVersion(major: 6, minor: 2, patch: 1)
        )
        #expect(state.toolchainVersions.isEmpty)
        #expect(state.sdkIdentifiers.isEmpty)
        #expect(await recorder.commands.count == 1)
    }

}

actor CommandRecorder {

    private var pendingResults: [EnvironmentCommandResult]
    private(set) var commands: [EnvironmentCommand] = []

    init(results: [EnvironmentCommandResult]) {
        pendingResults = results
    }

    func run(_ command: EnvironmentCommand) throws -> EnvironmentCommandResult {

        commands.append(command)
        guard !pendingResults.isEmpty else { throw TestFailure.unexpectedCommand }
        return pendingResults.removeFirst()

    }

}

private enum TestFailure: Error {

    case unexpectedCommand

}
