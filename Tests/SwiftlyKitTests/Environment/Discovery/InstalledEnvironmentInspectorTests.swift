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

    @Test("Removal inspection retains selection flags and marks unusable SDK state")
    func removalInspectionRetainsSafetyState() async throws {

        let toolchain = inspectorVersion("6.3.3")
        let recorder = RecordingSubprocessRunner(results: [
            .success(
                output: #"{"toolchains":["#
                    + #"{"inUse":true,"isDefault":true,"version":{"name":"6.3.3","type":"stable"}}"#
                    + #"]}"#
            ),
            .failure(standardError: "swift unavailable")
        ])
        let inspector = InstalledEnvironmentInspector(runner: recorder)
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))

        let inventory = try await inspector.inspectForRemoval(swiftly: swiftly, toolchain: toolchain, includeSDKs: true)

        #expect(inventory.toolchain(toolchain)?.isInUse == true)
        #expect(inventory.toolchain(toolchain)?.isDefault == true)
        #expect(inventory.sdkInspection == .unavailable)
        #expect(await recorder.commands.count == 2)
        #expect((await recorder.commands)[1].arguments == ["run", "swift", "sdk", "list", "+6.3.3"])
    }

    @Test("Removal inspection retains arbitrary registered SDK identifiers")
    func removalInspectionRetainsArbitrarySDKs() async throws {

        let toolchain = inspectorVersion("6.3.3")
        let recorder = RecordingSubprocessRunner(results: [
            .success(
                output: #"{"toolchains":["#
                    + #"{"inUse":false,"isDefault":false,"version":{"name":"6.3.3","type":"stable"}},"#
                    + #"{"inUse":false,"isDefault":false,"version":{"name":"6.2.1","type":"stable"}}"#
                    + #"]}"#
            ),
            .success(output: "custom-sdk\nswift-6.3.3-RELEASE_static-linux-0.1.0\n")
        ])
        let inspector = InstalledEnvironmentInspector(runner: recorder)
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))

        let inventory = try await inspector.inspectForRemoval(swiftly: swiftly, toolchain: toolchain, includeSDKs: true)

        #expect(inventory.sdks.map(\.identifier) == [
            "custom-sdk",
            "swift-6.3.3-RELEASE_static-linux-0.1.0"
        ])
        #expect(inventory.sdkInspection == .available(manager: toolchain))
        #expect(await recorder.commands.count == 2)
    }

    @Test("Malformed removal SDK output becomes uninspectable")
    func malformedRemovalSDKOutputIsUninspectable() async throws {

        let toolchain = inspectorVersion("6.3.3")
        let recorder = RecordingSubprocessRunner(results: [
            .success(
                output: #"{"toolchains":["#
                    + #"{"inUse":false,"isDefault":false,"version":{"name":"6.3.3","type":"stable"}}"#
                    + #"]}"#
            ),
            .success(output: "custom sdk\n")
        ])
        let inspector = InstalledEnvironmentInspector(runner: recorder)
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))

        let inventory = try await inspector.inspectForRemoval(swiftly: swiftly, toolchain: toolchain, includeSDKs: true)

        #expect(inventory.sdks.isEmpty)
        #expect(inventory.sdkInspection == .malformed)
    }

    @Test("Toolchain-only removal inspection skips the shared SDK registry")
    func toolchainOnlyInspectionDoesNotListSDKs() async throws {

        let toolchain = inspectorVersion("6.3.3")
        let recorder = RecordingSubprocessRunner(results: [
            .success(
                output: #"{"toolchains":["#
                    + #"{"inUse":false,"isDefault":false,"version":{"name":"6.3.3","type":"stable"}}"#
                    + #"]}"#
            )
        ])
        let inspector = InstalledEnvironmentInspector(runner: recorder)
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))

        let inventory = try await inspector.inspectForRemoval(
            swiftly: swiftly,
            toolchain: toolchain,
            includeSDKs: false
        )

        #expect(inventory.toolchain(toolchain) != nil)
        #expect(inventory.sdkInspection == .notRequested)
        #expect(await recorder.commands.count == 1)
    }

    @Test("SDK inspection uses an alternate manager when the paired toolchain is absent")
    func alternateManagerCanInspectSharedSDKRegistry() async throws {

        let paired = inspectorVersion("6.3.3")
        let manager = inspectorVersion("6.3.2")
        let recorder = RecordingSubprocessRunner(results: [
            .success(
                output: #"{"toolchains":["#
                    + #"{"inUse":false,"isDefault":false,"version":{"name":"6.3.2","type":"stable"}}"#
                    + #"]}"#
            ),
            .success(output: "swift-6.3.3-RELEASE_static-linux-0.1.0\n")
        ])
        let inspector = InstalledEnvironmentInspector(runner: recorder)
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))

        let inventory = try await inspector.inspectForRemoval(
            swiftly: swiftly,
            toolchain: paired,
            includeSDKs: true
        )

        #expect(inventory.sdkInspection == .available(manager: manager))
        #expect(inventory.contains(sdk: "swift-6.3.3-RELEASE_static-linux-0.1.0"))
        #expect((await recorder.commands).map(\.arguments) == [
            ["list", "--format", "json"],
            ["run", "swift", "sdk", "list", "+6.3.2"]
        ])
    }

    @Test("SDK inspection falls back when the preferred manager cannot run")
    func SDKInspectionFallsBackToAnotherManager() async throws {

        let preferred = inspectorVersion("6.3.3")
        let fallback = inspectorVersion("6.3.2")
        let recorder = RecordingSubprocessRunner(results: [
            .success(
                output: #"{"toolchains":["#
                    + #"{"inUse":false,"isDefault":false,"version":{"name":"6.3.3","type":"stable"}},"#
                    + #"{"inUse":false,"isDefault":false,"version":{"name":"6.3.2","type":"stable"}}"#
                    + #"]}"#
            ),
            .failure(standardError: "unsupported"),
            .success(output: "custom-sdk\n")
        ])
        let inspector = InstalledEnvironmentInspector(runner: recorder)
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))

        let inventory = try await inspector.inspectForRemoval(
            swiftly: swiftly,
            toolchain: preferred,
            includeSDKs: true
        )

        #expect(inventory.sdkInspection == .available(manager: fallback))
        #expect(inventory.sdks == [RegisteredSDK(identifier: "custom-sdk")])
        #expect((await recorder.commands).count == 3)
    }

    @Test("Malformed successful SDK output fails closed without fallback")
    func malformedSDKOutputDoesNotFallBack() async throws {

        let preferred = inspectorVersion("6.3.3")
        let recorder = RecordingSubprocessRunner(results: [
            .success(
                output: #"{"toolchains":["#
                    + #"{"inUse":false,"isDefault":false,"version":{"name":"6.3.3","type":"stable"}},"#
                    + #"{"inUse":false,"isDefault":false,"version":{"name":"6.3.2","type":"stable"}}"#
                    + #"]}"#
            ),
            .success(output: "malformed sdk identifier\n"),
            .success(output: "should not be read\n")
        ])
        let inspector = InstalledEnvironmentInspector(runner: recorder)
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))

        let inventory = try await inspector.inspectForRemoval(
            swiftly: swiftly,
            toolchain: preferred,
            includeSDKs: true
        )

        #expect(inventory.sdkInspection == .malformed)
        #expect(await recorder.commands.count == 2)
    }

    @Test("SDK inspection reports unavailable when no manager exists")
    func noSDKManagerIsNotTreatedAsEmptyRegistry() async throws {

        let recorder = RecordingSubprocessRunner(results: [
            .success(output: #"{"toolchains":[]}"#)
        ])
        let inspector = InstalledEnvironmentInspector(runner: recorder)
        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))

        let inventory = try await inspector.inspectForRemoval(
            swiftly: swiftly,
            toolchain: inspectorVersion("6.3.3"),
            includeSDKs: true
        )

        #expect(inventory.sdks.isEmpty)
        #expect(inventory.sdkInspection == .unavailable)
        #expect(await recorder.commands.count == 1)
    }

}

private func inspectorVersion(_ value: String) -> SwiftVersion {
    SwiftVersion(value)!
}
