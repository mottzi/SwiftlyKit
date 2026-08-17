import Foundation
import Testing
import SwiftlyKit
@testable import SwiftlyKit

@Suite("Environment removal")
struct EnvironmentRemovalPlanTests {

    private let version = SwiftVersion(major: 6, minor: 3, patch: 3)
    private var sdk: StaticLinuxSDK {
        StaticLinuxSDK(
            identifier: "swift-6.3.3-RELEASE_static-linux-0.1.0",
            version: "0.1.0"
        )
    }

    @Test("Plans have typed factories and stable Codable round trips")
    func planRoundTrips() throws {

        let plans: [EnvironmentRemovalPlan] = [
            .toolchain(version),
            try .staticLinuxSDK(identifier: sdk.identifier),
            try .environment(toolchain: version, staticLinuxSDKIdentifier: sdk.identifier)
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        for plan in plans {
            let data = try encoder.encode(plan)
            #expect(try decoder.decode(EnvironmentRemovalPlan.self, from: data) == plan)
        }

        let encoded = String(
            data: try encoder.encode(try EnvironmentRemovalPlan.environment(
                toolchain: version,
                staticLinuxSDKIdentifier: sdk.identifier
            )),
            encoding: .utf8
        )
        #expect(
            encoded == "{\"kind\":\"environment\",\"schemaVersion\":1,"
                + "\"sdkIdentifier\":\"swift-6.3.3-RELEASE_static-linux-0.1.0\","
                + "\"toolchain\":{\"major\":6,\"minor\":3,\"patch\":3}}"
        )

        let zeroVersionSDK = StaticLinuxSDK(
            identifier: "swift-0.1.0-RELEASE_static-linux-0.1.0",
            version: "0.1.0"
        )
        let zeroVersionPlan = try EnvironmentRemovalPlan.environment(
            toolchain: SwiftVersion(major: 0, minor: 1, patch: 0),
            staticLinuxSDKIdentifier: zeroVersionSDK.identifier
        )
        #expect(try decoder.decode(
            EnvironmentRemovalPlan.self,
            from: encoder.encode(zeroVersionPlan)
        ) == zeroVersionPlan)
    }

    @Test("Plans reject unsupported and malformed storage")
    func malformedPlansFail() {

        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            try decoder.decode(
                EnvironmentRemovalPlan.self,
                from: Data(
                    ("{\"schemaVersion\":99,\"kind\":\"toolchain\","
                        + "\"toolchain\":{\"major\":6,\"minor\":3,\"patch\":3},\"sdk\":null}").utf8
                )
            )
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(
                EnvironmentRemovalPlan.self,
                from: Data("{\"schemaVersion\":1,\"kind\":\"toolchain\",\"toolchain\":null,\"sdk\":null}".utf8)
            )
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(
                EnvironmentRemovalPlan.self,
                from: Data(
                    ("{\"schemaVersion\":1,\"kind\":\"staticLinuxSDK\",\"toolchain\":null,"
                        + "\"sdkIdentifier\":\"-unsafe\"}").utf8
                )
            )
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(
                EnvironmentRemovalPlan.self,
                from: Data(
                    ("{\"schemaVersion\":1,\"kind\":\"environment\",\"toolchain\":null,"
                        + "\"sdkIdentifier\":\"swift-6.3.3-RELEASE_static-linux-0.1.0\"}").utf8
                )
            )
        }
    }

    @Test("Factories reject unsafe SDK identifiers")
    func unsafeIdentifiersFail() {

        for identifier in ["", "-unsafe", "contains/slash", "contains\\slash", "contains space", "é"] {
            #expect(throws: SwiftlyKitError.self) {
                try EnvironmentRemovalPlan.staticLinuxSDK(identifier: identifier)
            }
            #expect(throws: SwiftlyKitError.self) {
                try EnvironmentRemovalPlan.environment(
                    toolchain: version,
                    staticLinuxSDKIdentifier: identifier
                )
            }
        }
    }

    @Test("Full removal preflights and removes SDK before its toolchain")
    func fullRemovalOrder() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let initial = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(
                version: version,
                isInUse: false,
                isDefault: false,
                selectionStateIsKnown: true
            )],
            sdks: [RegisteredSDK(identifier: sdk.identifier)],
            sdkInspection: .available(manager: version)
        )
        let afterSDK = EnvironmentRemovalInventory(
            toolchains: initial.toolchains,
            sdks: [],
            sdkInspection: .available(manager: version)
        )
        let afterToolchain = EnvironmentRemovalInventory(
            toolchains: [],
            sdks: [],
            sdkInspection: .available(manager: version)
        )
        let states = RemovalStateSequence(values: [initial, afterSDK, afterToolchain])
        let runner = RecordingSubprocessRunner(results: [.success(), .success()])
        let remover = EnvironmentRemover(
            runner: runner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in try await states.next() }
        )

        try await remover.remove(
            try EnvironmentRemovalPlan.environment(
                toolchain: version,
                staticLinuxSDKIdentifier: sdk.identifier
            )
        )

        let commands = await runner.commands
        #expect(commands.map(\.arguments) == [
            ["run", "swift", "sdk", "remove", sdk.identifier, "+6.3.3"],
            ["uninstall", "6.3.3", "--assume-yes"]
        ])
    }

    @Test("SDK-only and toolchain-only plans issue their exact command")
    func exactRemovalCommands() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let toolchain = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(version: version, isInUse: false, isDefault: false)],
            sdks: [
                RegisteredSDK(identifier: "custom-sdk"),
                RegisteredSDK(identifier: sdk.identifier)
            ],
            sdkInspection: .available(manager: version)
        )
        let noSDK = EnvironmentRemovalInventory(
            toolchains: toolchain.toolchains,
            sdks: [RegisteredSDK(identifier: "custom-sdk")],
            sdkInspection: .available(manager: version)
        )
        let noToolchain = EnvironmentRemovalInventory(toolchains: [], sdks: [], sdkInspection: .available(manager: version))

        let sdkRunner = RecordingSubprocessRunner(results: [.success()])
        let sdkStates = RemovalStateSequence(values: [toolchain, noSDK])
        let sdkRemover = EnvironmentRemover(
            runner: sdkRunner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in try await sdkStates.next() }
        )
        try await sdkRemover.remove(try EnvironmentRemovalPlan.staticLinuxSDK(identifier: sdk.identifier))
        #expect(await sdkRunner.commands.map(\.arguments) == [
            ["run", "swift", "sdk", "remove", sdk.identifier, "+6.3.3"]
        ])

        let toolchainRunner = RecordingSubprocessRunner(results: [.success()])
        let toolchainStates = RemovalStateSequence(values: [noSDK, noToolchain])
        let toolchainRemover = EnvironmentRemover(
            runner: toolchainRunner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in try await toolchainStates.next() }
        )
        try await toolchainRemover.remove(.toolchain(version))
        #expect(await toolchainRunner.commands.map(\.arguments) == [
            ["uninstall", "6.3.3", "--assume-yes"]
        ])
    }

    @Test("Absent exact targets are idempotent no-ops")
    func absentTargetsAreNoOps() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let runner = RecordingSubprocessRunner(results: [])
        let remover = EnvironmentRemover(
            runner: runner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in
                EnvironmentRemovalInventory(
                    toolchains: [],
                    sdks: [],
                    sdkInspection: .available(manager: version)
                )
            }
        )

        try await remover.remove(
            try EnvironmentRemovalPlan.environment(
                toolchain: version,
                staticLinuxSDKIdentifier: sdk.identifier
            )
        )

        #expect(await runner.commands.isEmpty)
    }

    @Test("Unrelated SDKs do not block exact toolchain or full-environment removal")
    func unrelatedSDKsDoNotBlockRemoval() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let toolchainState = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(version: version, isInUse: false, isDefault: false)],
            sdks: [RegisteredSDK(identifier: "custom-sdk")],
            sdkInspection: .notRequested
        )
        let noToolchain = EnvironmentRemovalInventory(
            toolchains: [],
            sdks: [RegisteredSDK(identifier: "custom-sdk")],
            sdkInspection: .notRequested
        )
        let toolchainRunner = RecordingSubprocessRunner(results: [.success()])
        let toolchainRemover = EnvironmentRemover(
            runner: toolchainRunner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in
                if await toolchainRunner.commands.isEmpty { return toolchainState }
                return noToolchain
            }
        )
        try await toolchainRemover.remove(.toolchain(version))
        #expect(await toolchainRunner.commands.map(\.arguments) == [
            ["uninstall", "6.3.3", "--assume-yes"]
        ])

        let initial = EnvironmentRemovalInventory(
            toolchains: toolchainState.toolchains,
            sdks: [
                RegisteredSDK(identifier: "custom-sdk"),
                RegisteredSDK(identifier: sdk.identifier)
            ],
            sdkInspection: .available(manager: version)
        )
        let afterSDK = EnvironmentRemovalInventory(
            toolchains: initial.toolchains,
            sdks: [RegisteredSDK(identifier: "custom-sdk")],
            sdkInspection: .available(manager: version)
        )
        let afterToolchain = EnvironmentRemovalInventory(
            toolchains: [],
            sdks: [RegisteredSDK(identifier: "custom-sdk")],
            sdkInspection: .available(manager: version)
        )
        let fullRunner = RecordingSubprocessRunner(results: [.success(), .success()])
        let states = RemovalStateSequence(values: [initial, afterSDK, afterToolchain])
        let fullRemover = EnvironmentRemover(
            runner: fullRunner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in try await states.next() }
        )
        try await fullRemover.remove(
            try EnvironmentRemovalPlan.environment(
                toolchain: version,
                staticLinuxSDKIdentifier: sdk.identifier
            )
        )
        #expect(await fullRunner.commands.map(\.arguments) == [
            ["run", "swift", "sdk", "remove", sdk.identifier, "+6.3.3"],
            ["uninstall", "6.3.3", "--assume-yes"]
        ])
    }

    @Test("SDK removal uses an alternate registered manager")
    func SDKRemovalUsesAlternateManager() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let manager = SwiftVersion(major: 6, minor: 3, patch: 2)
        let initial = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(version: manager, isInUse: false, isDefault: false)],
            sdks: [RegisteredSDK(identifier: sdk.identifier)],
            sdkInspection: .available(manager: manager)
        )
        let after = EnvironmentRemovalInventory(
            toolchains: initial.toolchains,
            sdks: [],
            sdkInspection: .available(manager: manager)
        )
        let runner = RecordingSubprocessRunner(results: [.success()])
        let states = RemovalStateSequence(values: [initial, after])
        let remover = EnvironmentRemover(
            runner: runner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in try await states.next() }
        )

        try await remover.remove(try EnvironmentRemovalPlan.staticLinuxSDK(identifier: sdk.identifier))

        #expect(await runner.commands.map(\.arguments) == [
            ["run", "swift", "sdk", "remove", sdk.identifier, "+6.3.2"]
        ])
    }

    @Test("SDK removal fails closed when no manager can inspect the registry")
    func SDKRemovalRequiresManager() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let state = EnvironmentRemovalInventory(
            toolchains: [],
            sdks: [RegisteredSDK(identifier: sdk.identifier)],
            sdkInspection: .unavailable
        )
        let runner = RecordingSubprocessRunner(results: [])
        let remover = EnvironmentRemover(
            runner: runner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in state }
        )

        await #expect(throws: SwiftlyKitError.environmentRemovalFailed(
            "No installed Swift toolchain can inspect the shared SDK registry."
        )) {
            try await remover.remove(try EnvironmentRemovalPlan.staticLinuxSDK(identifier: sdk.identifier))
        }
        #expect(await runner.commands.isEmpty)
    }

    @Test("Uninspectable SDK state refuses removal")
    func uninspectableSDKStateRefusesRemoval() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let state = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(version: version, isInUse: false, isDefault: false)],
            sdks: [],
            sdkInspection: .malformed
        )
        let runner = RecordingSubprocessRunner(results: [])
        let remover = EnvironmentRemover(
            runner: runner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in state }
        )

        await #expect(throws: SwiftlyKitError.environmentRemovalFailed(
            "Swiftly returned malformed shared SDK registry output."
        )) {
            try await remover.remove(try EnvironmentRemovalPlan.staticLinuxSDK(identifier: sdk.identifier))
        }
        #expect(await runner.commands.isEmpty)
    }

    @Test("SDK postcondition refuses an uninspectable state")
    func SDKPostconditionRequiresInspectableState() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let initial = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(version: version, isInUse: false, isDefault: false)],
            sdks: [RegisteredSDK(identifier: sdk.identifier)],
            sdkInspection: .available(manager: version)
        )
        let after = EnvironmentRemovalInventory(
            toolchains: initial.toolchains,
            sdks: [],
            sdkInspection: .malformed
        )
        let runner = RecordingSubprocessRunner(results: [.success()])
        let states = RemovalStateSequence(values: [initial, after])
        let remover = EnvironmentRemover(
            runner: runner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in try await states.next() }
        )

        await #expect(throws: SwiftlyKitError.environmentRemovalFailed(
            "Swiftly could not verify the SDK state after removal."
        )) {
            try await remover.remove(try EnvironmentRemovalPlan.staticLinuxSDK(identifier: sdk.identifier))
        }
    }

    @Test("Full removal rechecks state before removing the toolchain")
    func fullRemovalRechecksState() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let initial = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(version: version, isInUse: false, isDefault: false)],
            sdks: [RegisteredSDK(identifier: sdk.identifier)],
            sdkInspection: .available(manager: version)
        )
        let changed = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(version: version, isInUse: false, isDefault: true)],
            sdks: [RegisteredSDK(identifier: "new-sdk")],
            sdkInspection: .available(manager: version)
        )
        let runner = RecordingSubprocessRunner(results: [.success()])
        let states = RemovalStateSequence(values: [initial, changed])
        let remover = EnvironmentRemover(
            runner: runner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in try await states.next() }
        )

        await #expect(throws: SwiftlyKitError.self) {
            try await remover.remove(
                try EnvironmentRemovalPlan.environment(
                    toolchain: version,
                    staticLinuxSDKIdentifier: sdk.identifier
                )
            )
        }
        #expect(await runner.commands.count == 1)
    }

    @Test("Full removal skips an already absent second target")
    func fullRemovalSkipsAbsentToolchain() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let initial = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(version: version, isInUse: false, isDefault: false)],
            sdks: [RegisteredSDK(identifier: sdk.identifier)],
            sdkInspection: .available(manager: version)
        )
        let afterExternalToolchainRemoval = EnvironmentRemovalInventory(
            toolchains: [],
            sdks: [],
            sdkInspection: .available(manager: version)
        )
        let runner = RecordingSubprocessRunner(results: [.success()])
        let states = RemovalStateSequence(values: [initial, afterExternalToolchainRemoval])
        let remover = EnvironmentRemover(
            runner: runner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in try await states.next() }
        )

        try await remover.remove(
            try EnvironmentRemovalPlan.environment(
                toolchain: version,
                staticLinuxSDKIdentifier: sdk.identifier
            )
        )

        #expect(await runner.commands.count == 1)
    }

    @Test("Removal forwards output and progress events")
    func removalForwardsEvents() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let initial = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(version: version, isInUse: false, isDefault: false)],
            sdks: [RegisteredSDK(identifier: sdk.identifier)],
            sdkInspection: .available(manager: version)
        )
        let after = EnvironmentRemovalInventory(
            toolchains: initial.toolchains,
            sdks: [],
            sdkInspection: .available(manager: version)
        )
        let runner = RecordingSubprocessRunner(results: [.success(output: "removed\n")])
        let states = RemovalStateSequence(values: [initial, after])
        let events = EventCollector()
        let remover = EnvironmentRemover(
            runner: runner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in try await states.next() }
        )

        try await remover.remove(try EnvironmentRemovalPlan.staticLinuxSDK(identifier: sdk.identifier), onEvent: { event in
            await events.append(event)
        })

        let received = await events.values
        #expect(received.contains { if case .output = $0 { true } else { false } })
        #expect(received.contains {
            guard case .progress(let progress) = $0 else { return false }
            return progress.operation == .removingEnvironment
        })
    }

    @Test("Cancellation after an SDK prefix leaves a retryable plan")
    func cancellationCanRetrySamePlan() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let initial = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(version: version, isInUse: false, isDefault: false)],
            sdks: [RegisteredSDK(identifier: sdk.identifier)],
            sdkInspection: .available(manager: version)
        )
        let afterSDK = EnvironmentRemovalInventory(
            toolchains: initial.toolchains,
            sdks: [],
            sdkInspection: .available(manager: version)
        )
        let afterToolchain = EnvironmentRemovalInventory(
            toolchains: [],
            sdks: [],
            sdkInspection: .available(manager: version)
        )
        let states = CancellationAfterSDKSequence(
            initial: initial,
            afterSDK: afterSDK,
            afterToolchain: afterToolchain
        )
        let runner = RecordingSubprocessRunner(results: [.success(), .success()])
        let remover = EnvironmentRemover(
            runner: runner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in try await states.next() }
        )

        await #expect(throws: CancellationError.self) {
            try await remover.remove(
                try EnvironmentRemovalPlan.environment(
                    toolchain: version,
                    staticLinuxSDKIdentifier: sdk.identifier
                )
            )
        }
        try await remover.remove(
            try EnvironmentRemovalPlan.environment(
                toolchain: version,
                staticLinuxSDKIdentifier: sdk.identifier
            )
        )
        #expect(await runner.commands.map(\.arguments) == [
            ["run", "swift", "sdk", "remove", sdk.identifier, "+6.3.3"],
            ["uninstall", "6.3.3", "--assume-yes"]
        ])
    }

    @Test("Facade removal participates in the shared mutation gate")
    func facadeRemovalUsesMutationGate() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-RemovalGate") { directory in
            let swiftly = SwiftlyInstallation(executableURL: directory.appending(path: "swiftly"))
            let initial = EnvironmentRemovalInventory(
                toolchains: [RegisteredToolchain(version: version, isInUse: false, isDefault: false)],
                sdks: [RegisteredSDK(identifier: sdk.identifier)],
                sdkInspection: .available(manager: version)
            )
            let after = EnvironmentRemovalInventory(
                toolchains: initial.toolchains,
                sdks: [],
                sdkInspection: .available(manager: version)
            )
            let states = RemovalStateSequence(values: [initial, after, initial, after])
            let runner = BlockingRemovalRunner()
            let remover = EnvironmentRemover(
                runner: runner,
                detectSwiftly: { swiftly },
                inspect: { _, _, _ in try await states.next() }
            )
            let gate = MutationGate(lockFile: directory.appending(path: "mutation.lock"))
            let firstKit = SwiftlyKit(
                mutationGate: gate,
                assessor: EnvironmentAssessor(),
                preparer: EnvironmentPreparer(),
                swiftPM: SwiftPM(),
                remover: remover
            )
            let secondKit = SwiftlyKit(
                mutationGate: gate,
                assessor: EnvironmentAssessor(),
                preparer: EnvironmentPreparer(),
                swiftPM: SwiftPM(),
                remover: remover
            )

            let plan = try EnvironmentRemovalPlan.staticLinuxSDK(identifier: sdk.identifier)
            let first = Task { try await firstKit.removeEnvironment(plan) }
            await runner.waitUntilFirstCommandStarts()
            let second = Task { try await secondKit.removeEnvironment(plan) }
            try await Task.sleep(for: .milliseconds(20))
            #expect(await runner.commands.count == 1)

            await runner.releaseFirstCommand()
            try await first.value
            try await second.value
            #expect(await runner.commands.count == 2)
        }
    }

    @Test("Toolchain removal refuses active or default state before mutation")
    func unsafeToolchainRemoval() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let state = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(
                version: version,
                isInUse: true,
                isDefault: true,
                selectionStateIsKnown: true
            )],
            sdks: [],
            sdkInspection: .available(manager: version)
        )
        let runner = RecordingSubprocessRunner(results: [])
        let remover = EnvironmentRemover(
            runner: runner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in state }
        )

        await #expect(throws: SwiftlyKitError.unsafeEnvironmentRemoval(
            "Swift 6.3.3 is currently in use and will not be deselected automatically."
        )) {
            try await remover.remove(EnvironmentRemovalPlan.toolchain(version))
        }
        #expect(await runner.commands.isEmpty)
    }

    @Test("Unknown selection state refuses toolchain removal")
    func unknownSelectionStateRefusesRemoval() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let state = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(
                version: version,
                isInUse: false,
                isDefault: false,
                selectionStateIsKnown: false
            )],
            sdks: [],
            sdkInspection: .available(manager: version)
        )
        let runner = RecordingSubprocessRunner(results: [])
        let remover = EnvironmentRemover(
            runner: runner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in state }
        )

        await #expect(throws: SwiftlyKitError.unsafeEnvironmentRemoval(
            "Swiftly did not report whether Swift 6.3.3 is active or default."
        )) {
            try await remover.remove(.toolchain(version))
        }
        #expect(await runner.commands.isEmpty)
    }

    @Test("Failed removal preserves a bounded diagnostic")
    func failedRemovalDiagnosticIsBounded() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let state = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(version: version, isInUse: false, isDefault: false)],
            sdks: [],
            sdkInspection: .available(manager: version)
        )
        let diagnostic = String(repeating: "x", count: 12 * 1024)
        let runner = RecordingSubprocessRunner(results: [.failure(standardError: diagnostic)])
        let remover = EnvironmentRemover(
            runner: runner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in state }
        )

        do {
            try await remover.remove(.toolchain(version))
            Issue.record("Removal should fail when Swiftly reports a command failure.")
        } catch let error as SwiftlyKitError {
            guard case .environmentRemovalFailed(let detail) = error else {
                Issue.record("Removal returned the wrong public error.")
                return
            }
            #expect(detail.count == 8 * 1024)
        }
    }

    @Test("Removal fails when the requested target remains present")
    func targetStillPresentFailsPostcondition() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let state = EnvironmentRemovalInventory(
            toolchains: [RegisteredToolchain(version: version, isInUse: false, isDefault: false)],
            sdks: [],
            sdkInspection: .available(manager: version)
        )
        let runner = RecordingSubprocessRunner(results: [.success()])
        let remover = EnvironmentRemover(
            runner: runner,
            detectSwiftly: { swiftly },
            inspect: { _, _, _ in state }
        )

        await #expect(throws: SwiftlyKitError.environmentRemovalFailed(
            "Swiftly still reports the requested resource after removal."
        )) {
            try await remover.remove(.toolchain(version))
        }
    }

}

private actor RemovalStateSequence {

    var values: [EnvironmentRemovalInventory]

    init(values: [EnvironmentRemovalInventory]) {
        self.values = values
    }

    func next() throws -> EnvironmentRemovalInventory {
        guard !values.isEmpty else { throw CancellationError() }
        return values.removeFirst()
    }

}

private actor EventCollector {

    private(set) var values: [SwiftlyKitEvent] = []

    func append(_ event: SwiftlyKitEvent) {
        values.append(event)
    }

}

private actor CancellationAfterSDKSequence {

    private let initial: EnvironmentRemovalInventory
    private let afterSDK: EnvironmentRemovalInventory
    private let afterToolchain: EnvironmentRemovalInventory
    private var callCount = 0

    init(
        initial: EnvironmentRemovalInventory,
        afterSDK: EnvironmentRemovalInventory,
        afterToolchain: EnvironmentRemovalInventory
    ) {
        self.initial = initial
        self.afterSDK = afterSDK
        self.afterToolchain = afterToolchain
    }

    func next() throws -> EnvironmentRemovalInventory {

        callCount += 1
        switch callCount {
            case 1:
                return initial
            case 2:
                // the SDK prefix has already succeeded; cancellation interrupts
                // the post-command state verification
                throw CancellationError()
            case 3:
                return afterSDK
            default:
                return afterToolchain
        }
    }

}

private actor BlockingRemovalRunner: SubprocessRunning {

    private(set) var commands: [SubprocessCommand] = []
    private var firstCommandStarted = false
    private var firstCommandWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func run(_ command: SubprocessCommand, onOutput: SubprocessOutputHandler?) async throws -> SubprocessResult {

        commands.append(command)

        if commands.count == 1 {
            firstCommandStarted = true
            firstCommandWaiter?.resume()
            firstCommandWaiter = nil
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }

        return .success()
    }

    func waitUntilFirstCommandStarts() async {
        if firstCommandStarted { return }
        await withCheckedContinuation { continuation in
            firstCommandWaiter = continuation
        }
    }

    func releaseFirstCommand() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

}
