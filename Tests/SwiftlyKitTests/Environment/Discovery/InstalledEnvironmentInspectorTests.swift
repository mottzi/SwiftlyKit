import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Installed environment inspector")
struct InstalledEnvironmentInspectorTests {

    @Test("A complete inventory reads the Swiftly registry once")
    func completeInventoryReadsRegistryOnce() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let recorder = RecordingSubprocessRunner(results: [
            .success(output: """
                    {"toolchains":[
                        {"version":{"name":"6.2.1","type":"stable"}},
                        {"version":{"name":"6.3.0","type":"stable"}}
                    ]}
                    """),
            .success(output: "swift-6.3.0-RELEASE_static-linux-0.0.1\n"),
            .success(output: "swift-6.2.1-RELEASE_static-linux-0.0.1\n")
        ])

        let inspector = InstalledEnvironmentInspector(
            runner: recorder,
            isToolchainUsable: { _ in true }
        )

        let inventory = try await inspector.inspectAll(swiftly: swiftly)

        #expect(inventory.toolchains == [
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
            .success(output: """
                    {"toolchains":[
                        {"version":{"name":"6.2.1","type":"stable"}},
                        {"version":{"name":"main-snapshot","type":"snapshot"}}
                    ]}
                    """),
            .success(output: "swift-6.2.1-RELEASE_static-linux-0.0.1\n")
        ])

        let inspector = InstalledEnvironmentInspector(
            runner: recorder,
            isToolchainUsable: { _ in true }
        )

        let state = try await inspector.inspect(
            swiftly: swiftly,
            selectedToolchain: SwiftVersion(major: 6, minor: 2, patch: 1)
        )

        #expect(state.toolchains == [SwiftVersion(major: 6, minor: 2, patch: 1)])
        #expect(state.sdks.map(\.identifier) == ["swift-6.2.1-RELEASE_static-linux-0.0.1"])
        let commands = await recorder.commands
        #expect(commands[0].arguments == ["list", "--format", "json"])
        #expect(commands[1].arguments == ["run", "swift", "sdk", "list", "+6.2.1"])

    }

    @Test("Does not ask SwiftPM for SDKs when the exact toolchain is absent")
    func absentToolchainSkipsSDKProbe() async throws {

        let recorder = RecordingSubprocessRunner(results: [
            .success(output: #"{"toolchains":[]}"#)
        ])
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))

        let inspector = InstalledEnvironmentInspector(
            runner: recorder,
            isToolchainUsable: { _ in true }
        )

        let state = try await inspector.inspect(
            swiftly: swiftly,
            selectedToolchain: SwiftVersion(major: 6, minor: 2, patch: 1)
        )

        #expect(state.sdks.isEmpty)
        #expect(await recorder.commands.count == 1)

    }

    @Test("Registry entries without an executable toolchain are unavailable")
    func staleRegistryEntry() async throws {

        let recorder = RecordingSubprocessRunner(results: [
            .success(output: #"{"toolchains":[{"version":{"name":"6.2.1","type":"stable"}}]}"#)
        ])
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let inspector = InstalledEnvironmentInspector(
            runner: recorder,
            isToolchainUsable: { _ in false }
        )

        let state = try await inspector.inspect(
            swiftly: swiftly,
            selectedToolchain: SwiftVersion(major: 6, minor: 2, patch: 1)
        )
        #expect(state.toolchains.isEmpty)
        #expect(state.sdks.isEmpty)
        #expect(await recorder.commands.count == 1)
    }

    @Test("Swiftly inventory retains unique stable semantic versions only")
    func parsesStableToolchains() async throws {

        let recorder = RecordingSubprocessRunner(results: [.success(output: """
            {
              "toolchains": [
                {"inUse":false,"isDefault":false,"version":{"name":"xcode","type":"system"}},
                {"inUse":true,"isDefault":true,"version":{"name":"6.2.4","type":"stable"}},
                {"inUse":false,"isDefault":false,"version":{"name":"6.3","type":"stable"}},
                {"inUse":false,"isDefault":false,"version":{"name":"6.2.4","type":"stable"}},
                {"inUse":false,"isDefault":false,"version":{"name":"main-snapshot","type":"snapshot"}}
              ]
            }
            """)])
        let inspector = InstalledEnvironmentInspector(
            runner: recorder,
            isToolchainUsable: { _ in true }
        )
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))

        let inventory = try await inspector.inspect(
            swiftly: swiftly,
            selectedToolchain: inspectorVersion("9.9.9")
        )

        #expect(inventory.toolchains == [inspectorVersion("6.3"), inspectorVersion("6.2.4")])
    }

    @Test("Malformed Swiftly JSON is rejected")
    func rejectsMalformedToolchainInventory() async {

        let inspector = InstalledEnvironmentInspector(
            runner: RecordingSubprocessRunner(results: [.success(output: "{}")]),
            isToolchainUsable: { _ in true }
        )
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))

        await #expect(throws: InstalledEnvironmentError.invalidOutput) {
            try await inspector.inspect(
                swiftly: swiftly,
                selectedToolchain: inspectorVersion("6.3")
            )
        }
    }

    @Test("SDK inventory is scoped to the toolchain used to list it")
    func parsesStaticSDKs() async throws {

        let toolchain = inspectorVersion("6.3.3")
        let recorder = RecordingSubprocessRunner(results: [
            .success(output: #"{"toolchains":[{"version":{"name":"6.3.3","type":"stable"}}]}"#),
            .success(output: """
            swift-6.3.3-RELEASE_static-linux-0.1.0
            custom-sdk
            swift-6.3.3-RELEASE_static-linux-0.1.0
            warning: static-linux-sdk unavailable
            """)
        ])
        let inspector = InstalledEnvironmentInspector(
            runner: recorder,
            isToolchainUsable: { _ in true }
        )
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))

        let inventory = try await inspector.inspect(swiftly: swiftly, selectedToolchain: toolchain)

        #expect(inventory.sdks == [InstalledStaticLinuxSDK(
            toolchainVersion: toolchain,
            identifier: "swift-6.3.3-RELEASE_static-linux-0.1.0"
        )])
    }

}

private func inspectorVersion(_ value: String) -> SwiftVersion {
    SwiftVersion(parsing: value)!
}
