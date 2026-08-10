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
            SubprocessResult(succeeded: true, standardOutput: #"{"toolchains":[]}"#, standardError: "")
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
            SubprocessResult(
                succeeded: true,
                standardOutput: #"{"toolchains":[{"version":{"name":"6.2.1","type":"stable"}}]}"#,
                standardError: ""
            )
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
    func parsesStableToolchains() throws {

        let data = Data("""
            {
              "toolchains": [
                {"inUse":false,"isDefault":false,"version":{"name":"xcode","type":"system"}},
                {"inUse":true,"isDefault":true,"version":{"name":"6.2.4","type":"stable"}},
                {"inUse":false,"isDefault":false,"version":{"name":"6.3","type":"stable"}},
                {"inUse":false,"isDefault":false,"version":{"name":"6.2.4","type":"stable"}},
                {"inUse":false,"isDefault":false,"version":{"name":"main-snapshot","type":"snapshot"}}
              ]
            }
            """.utf8)

        let toolchains = try InstalledEnvironmentInspector.parseSwiftlyList(data)
        #expect(toolchains == [inspectorVersion("6.3"), inspectorVersion("6.2.4")])
    }

    @Test("Malformed Swiftly JSON is rejected")
    func rejectsMalformedToolchainInventory() {
        #expect(throws: InstalledEnvironmentError.invalidOutput) {
            try InstalledEnvironmentInspector.parseSwiftlyList(Data("{}".utf8))
        }
    }

    @Test("SDK inventory is scoped to the toolchain used to list it")
    func parsesStaticSDKs() {

        let toolchain = inspectorVersion("6.3.3")
        let sdks = InstalledEnvironmentInspector.parseSDKList(
            """
            swift-6.3.3-RELEASE_static-linux-0.1.0
            custom-sdk
            swift-6.3.3-RELEASE_static-linux-0.1.0
            warning: static-linux-sdk unavailable
            """,
            toolchainVersion: toolchain
        )

        #expect(sdks == [InstalledStaticLinuxSDK(
            toolchainVersion: toolchain,
            identifier: "swift-6.3.3-RELEASE_static-linux-0.1.0"
        )])
    }

}

private func inspectorVersion(_ value: String) -> SwiftVersion {
    SwiftVersion(parsing: value)!
}
