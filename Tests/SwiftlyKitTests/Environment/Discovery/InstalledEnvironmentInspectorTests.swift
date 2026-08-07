import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Installed environment inspector")
struct InstalledEnvironmentInspectorTests {

    @Test("A complete inventory reads the Swiftly registry once")
    func completeInventoryReadsRegistryOnce() async throws {
        
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let recorder = RecordingSubprocessRunner(results: [
            SubprocessResult(
                succeeded: true,
                standardOutput: """
                    {"toolchains":[
                        {"version":{"name":"6.2.1","type":"stable"}},
                        {"version":{"name":"6.3.0","type":"stable"}}
                    ]}
                    """,
                standardError: ""
            ),
            SubprocessResult(
                succeeded: true,
                standardOutput: "swift-6.3.0-RELEASE_static-linux-0.0.1\n",
                standardError: ""
            ),
            SubprocessResult(
                succeeded: true,
                standardOutput: "swift-6.2.1-RELEASE_static-linux-0.0.1\n",
                standardError: ""
            )
        ])
        
        let inventory = try await InstalledEnvironmentInspector(
            runner: recorder,
            isToolchainUsable: { _ in true }
        ).inspectAll(swiftly: swiftly)
        
        #expect(inventory.toolchains.map(\.version) == [
            SwiftVersion(major: 6, minor: 3, patch: 0),
            SwiftVersion(major: 6, minor: 2, patch: 1)
        ])
        #expect(inventory.sdks.count == 2)
        let commands = await recorder.commands
        #expect(commands.count == 3)
        #expect(commands.filter { $0.arguments == ["list", "--format", "json"] }.count == 1)
    }

    @Test("Lists stable toolchains and SDKs through the exact selected toolchain")
    func exactInspection() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let recorder = RecordingSubprocessRunner(results: [
            SubprocessResult(
                succeeded: true,
                standardOutput: """
                    {"toolchains":[
                        {"version":{"name":"6.2.1","type":"stable"}},
                        {"version":{"name":"main-snapshot","type":"snapshot"}}
                    ]}
                    """,
                standardError: ""
            ),
            SubprocessResult(
                succeeded: true,
                standardOutput: "swift-6.2.1-RELEASE_static-linux-0.0.1\n",
                standardError: ""
            )
        ])

        let state = try await InstalledEnvironmentInspector(
            runner: recorder,
            isToolchainUsable: { _ in true }
        ).inspect(
            swiftly: swiftly,
            selectedToolchain: SwiftVersion(major: 6, minor: 2, patch: 1)
        )

        #expect(state.toolchains.map(\.version) == [SwiftVersion(major: 6, minor: 2, patch: 1)])
        #expect(state.sdks.map(\.identifier) == ["swift-6.2.1-RELEASE_static-linux-0.0.1"])
        let commands = await recorder.commands
        #expect(commands[0].arguments == ["list", "--format", "json"])
        #expect(commands[1].arguments == ["run", "swift", "sdk", "list", "+6.2.1"])

    }

    @Test("Does not ask SwiftPM for SDKs when the exact toolchain is absent")
    func absentToolchainSkipsSDKProbe() async throws {

        let recorder = RecordingSubprocessRunner(results: [
            SubprocessResult(succeeded: true, standardOutput: #"{"toolchains":[]}"#, standardError: "")
        ])
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))

        let state = try await InstalledEnvironmentInspector(
            runner: recorder,
            isToolchainUsable: { _ in true }
        ).inspect(
            swiftly: swiftly,
            selectedToolchain: SwiftVersion(major: 6, minor: 2, patch: 1)
        )

        #expect(state.sdks.isEmpty)
        #expect(await recorder.commands.count == 1)

    }
    
    @Test("Registry entries without an executable toolchain are unavailable")
    func staleRegistryEntry() async throws {
        
        let recorder = RecordingSubprocessRunner(results: [
            SubprocessResult(
                succeeded: true,
                standardOutput: #"{"toolchains":[{"version":{"name":"6.2.1","type":"stable"}}]}"#,
                standardError: ""
            )
        ])
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let state = try await InstalledEnvironmentInspector(
            runner: recorder,
            isToolchainUsable: { _ in false }
        ).inspect(
            swiftly: swiftly,
            selectedToolchain: SwiftVersion(major: 6, minor: 2, patch: 1)
        )
        #expect(state.toolchains.isEmpty)
        #expect(state.sdks.isEmpty)
        #expect(await recorder.commands.count == 1)
    }

}
