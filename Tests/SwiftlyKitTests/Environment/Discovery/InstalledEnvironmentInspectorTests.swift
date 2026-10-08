import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Installed environment inspector")
struct InstalledEnvironmentInspectorTests {

    @Test("A complete inventory reads the Swiftly registry once")
    func completeInventoryReadsRegistryOnce() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let recorder = ParallelSDKInventoryRunner(versions: [inspectorVersion("6.2.1"), inspectorVersion("6.3.0")])

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
        #expect(inventory.sdks.map(\.toolchainVersion) == inventory.toolchains)
        #expect(inventory.sdks.map(\.identifier) == [
            "swift-6.3.0-RELEASE_static-linux-0.0.1",
            "swift-6.2.1-RELEASE_static-linux-0.0.1"
        ])
        #expect(await recorder.maximumConcurrentSDKProbes == 2)
        let commands = await recorder.commands
        #expect(commands.count == 3)
        #expect(commands.filter { $0.arguments == ["list", "--format", "json"] }.count == 1)
    }

    @Test("One failed SDK probe preserves other installed compiler observations")
    func concurrentProbeFailureIsIsolated() async throws {

        let older = inspectorVersion("6.2.1")
        let newer = inspectorVersion("6.3.0")
        let runner = ParallelSDKInventoryRunner(versions: [older, newer], failing: [newer])
        let inspector = InstalledEnvironmentInspector(runner: runner, isToolchainUsable: { _ in true })
        let inventory = try await inspector.inspectAll(
            swiftly: SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        )

        #expect(inventory.toolchains == [newer, older])
        #expect(inventory.sdks.map(\.toolchainVersion) == [older])
        #expect(await runner.maximumConcurrentSDKProbes == 2)
    }

    @Test("Cancelling full inventory cancels its structured SDK probes")
    func concurrentProbeCancellation() async throws {

        let runner = ParallelSDKInventoryRunner(
            versions: [inspectorVersion("6.2.1"), inspectorVersion("6.3.0")],
            waitsForCancellation: true
        )
        let inspector = InstalledEnvironmentInspector(runner: runner, isToolchainUsable: { _ in true })
        let request = Task {
            try await inspector.inspectAll(
                swiftly: SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
            )
        }
        await runner.waitUntilSDKProbesStarted()
        request.cancel()

        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await runner.activeSDKProbes == 0)
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

    @Test("An absent custom SDK registry is empty without running SwiftPM or creating it")
    func absentCustomSDKRegistryIsReadOnly() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Inspector") { directory in
            let storageRoot = directory.appending(path: "environment")
            let executable = storageRoot.appending(path: "bin/swiftly")
            try makeInspectorExecutable(at: executable)
            try makeInspectorExecutable(at: storageRoot.appending(
                path: "toolchains/swift-6.2.1-RELEASE.xctoolchain/usr/bin/swift"
            ))
            let swiftly = try #require(
                try await SwiftlyInstallation.detect(
                    storage: .directory(storageRoot),
                    versionProbe: { _ in "1.2.3" }
                )
            )
            let runner = RecordingSubprocessRunner(results: [
                .success(output: #"{"toolchains":[{"version":{"name":"6.2.1","type":"stable"}}]}"#)
            ])
            let inspector = InstalledEnvironmentInspector(
                runner: runner,
                isToolchainUsable: { _ in true }
            )

            let inventory = try await inspector.inspectAll(swiftly: swiftly)

            #expect(inventory.toolchains == [inspectorVersion("6.2.1")])
            #expect(inventory.sdks.isEmpty)
            #expect(!FileManager.default.fileExists(
                atPath: storageRoot.appending(path: "swift-sdks").path(percentEncoded: false)
            ))
            #expect(await runner.commands.map(\.arguments) == [
                ["list", "--format", "json"]
            ])
        }
    }

    @Test("Custom toolchain usability rejects an executable symlink outside its namespace")
    func customToolchainSymlinkEscapeIsRejected() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Inspector") { directory in
            let storageRoot = directory.appending(path: "environment")
            let version = inspectorVersion("6.2.1")
            let escapedExecutable = directory.appending(path: "outside/swift")
            let toolchainExecutable = storageRoot.appending(
                path: "toolchains/swift-6.2.1-RELEASE.xctoolchain/usr/bin/swift"
            )
            let swiftlyExecutable = storageRoot.appending(path: "bin/swiftly")
            try makeInspectorExecutable(at: swiftlyExecutable)
            try makeInspectorExecutable(at: escapedExecutable)
            try FileManager.default.createDirectory(
                at: toolchainExecutable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: toolchainExecutable,
                withDestinationURL: escapedExecutable
            )

            let swiftly = try #require(
                try await SwiftlyInstallation.detect(
                    storage: .directory(storageRoot),
                    versionProbe: { _ in "1.2.3" }
                )
            )
            let recorder = RecordingSubprocessRunner(results: [
                .success(output: #"{"toolchains":[{"version":{"name":"6.2.1","type":"stable"}}]}"#)
            ])
            let inspector = InstalledEnvironmentInspector(runner: recorder)

            let inventory = try await inspector.inspect(
                swiftly: swiftly,
                selectedToolchain: version
            )

            #expect(inventory.toolchains.isEmpty)
            #expect(inventory.sdks.isEmpty)
            #expect(await recorder.commands.count == 1)
        }
    }

    @Test("An existing custom SDK registry is inspected with its exact SwiftPM path")
    func customSDKRegistryUsesExactPath() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Inspector") { directory in
            let storageRoot = directory.appending(path: "environment")
            let sdkDirectory = storageRoot.appending(path: "swift-sdks")
            try FileManager.default.createDirectory(at: sdkDirectory, withIntermediateDirectories: true)
            let executable = storageRoot.appending(path: "bin/swiftly")
            try makeInspectorExecutable(at: executable)
            try makeInspectorExecutable(at: storageRoot.appending(
                path: "toolchains/swift-6.2.1-RELEASE.xctoolchain/usr/bin/swift"
            ))
            let swiftly = try #require(
                try await SwiftlyInstallation.detect(
                    storage: .directory(storageRoot),
                    versionProbe: { _ in "1.2.3" }
                )
            )
            let runner = RecordingSubprocessRunner(results: [
                .success(output: #"{"toolchains":[{"version":{"name":"6.2.1","type":"stable"}}]}"#),
                .success(output: "swift-6.2.1-RELEASE_static-linux-0.0.1\n")
            ])
            let inspector = InstalledEnvironmentInspector(
                runner: runner,
                isToolchainUsable: { _ in true }
            )

            _ = try await inspector.inspect(
                swiftly: swiftly,
                selectedToolchain: inspectorVersion("6.2.1")
            )

            let commands = await runner.commands
            let sdkCommand = try #require(commands.last)
            #expect(commands.count == 2)
            #expect(sdkCommand.arguments.prefix(5) == [
                "run", "swift", "sdk", "list", "--swift-sdks-path"
            ])
            let sdkPathArgument = try #require(sdkCommand.arguments.dropFirst(5).first)
            #expect(URL(filePath: sdkPathArgument).pathComponents == sdkDirectory.pathComponents)
            #expect(sdkCommand.arguments.suffix(1) == ["+6.2.1"])
        }
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

/// Keys responses by exact compiler and holds SDK probes until all children have started.
private actor ParallelSDKInventoryRunner: SubprocessRunning {

    private let versions: [SwiftVersion]
    private let failing: Set<SwiftVersion>
    private let waitsForCancellation: Bool
    private var startedSDKProbes = 0
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var commands: [SubprocessCommand] = []
    private(set) var maximumConcurrentSDKProbes = 0
    private(set) var activeSDKProbes = 0

    init(versions: [SwiftVersion], failing: Set<SwiftVersion> = [], waitsForCancellation: Bool = false) {
        self.versions = versions
        self.failing = failing
        self.waitsForCancellation = waitsForCancellation
    }

    func run(_ command: SubprocessCommand, onOutput: SubprocessOutputHandler?) async throws -> SubprocessResult {

        commands.append(command)
        if command.arguments == ["list", "--format", "json"] {
            let entries = versions.map { #"{"version":{"name":""# + $0.description + #"","type":"stable"}}"# }
            return .success(output: #"{"toolchains":["# + entries.joined(separator: ",") + "]}")
        }

        let selection = try #require(command.arguments.last)
        let version = try #require(SwiftVersion(String(selection.dropFirst())))
        activeSDKProbes += 1
        maximumConcurrentSDKProbes = max(maximumConcurrentSDKProbes, activeSDKProbes)
        defer { activeSDKProbes -= 1 }
        startedSDKProbes += 1
        if startedSDKProbes == versions.count {
            let startWaiters = startWaiters
            self.startWaiters.removeAll()
            startWaiters.forEach { $0.resume() }
        }

        if waitsForCancellation {
            try await Task.sleep(for: .seconds(30))
            Issue.record("Inventory should have cancelled all probes")
        } else {
            await withCheckedContinuation { continuation in
                completionWaiters.append(continuation)
                if startedSDKProbes == versions.count {
                    let completionWaiters = completionWaiters
                    self.completionWaiters.removeAll()
                    completionWaiters.forEach { $0.resume() }
                }
            }
        }

        if failing.contains(version) { return .failure(standardError: "SDK manager unavailable") }
        return .success(output: "swift-\(version)-RELEASE_static-linux-0.0.1\n")
    }

    func waitUntilSDKProbesStarted() async {
        guard startedSDKProbes < versions.count else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

}

private func inspectorVersion(_ value: String) -> SwiftVersion {
    SwiftVersion(value)!
}

private func makeInspectorExecutable(at url: URL) throws {

    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\nprintf '1.2.3\\n'\n".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path(percentEncoded: false)
    )
}
