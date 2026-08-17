import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Environment preparer")
struct EnvironmentPreparerTests {

    private let version = SwiftVersion(major: 6, minor: 2, patch: 1)
    private let sdk = StaticLinuxSDK(
        identifier: "swift-6.2.1-RELEASE_static-linux-0.0.1",
        version: "0.0.1"
    )
    private let sdkMetadata = StaticLinuxSDKMetadata(
        downloadURL: URL(string: "https://download.swift.org/swift-6.2.1/sdk.tar.gz")!,
        checksum: String(repeating: "a", count: 64),
        supportedArchitectures: [.arm64]
    )!

    @Test("A ready environment inspects once and performs no download or mutation command")
    func readyIsNoOp() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [])
        let inspections = Counter()
        let validations = Counter()
        let plans = PlanRecorder()
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            downloadPackage: { _, _ in Issue.record("download must not run") },
            detectSwiftly: { swiftly },
            inspect: { _, _ in
                await inspections.increment()
                return self.inventory(includesToolchain: true, includesSDK: true)
            },
            locateSDK: { _ in URL(filePath: "/tmp/sdk.artifactbundle") },
            revalidate: { _ in await validations.increment() }
        )

        let result = try await preparer.prepare(
            try assessment(requires: []),
            recordRemovalPlan: { plan in await plans.append(plan) }
        )

        #expect(result.swiftVersion == version)
        #expect(await inspections.value == 1)
        #expect(await validations.value == 1)
        #expect(await commands.commands.isEmpty)
        #expect(await plans.values.isEmpty)

    }

    @Test("Installs exact components without exposing bound SwiftPM values to commands")
    func installsMissingComponents() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [
            .success(),
            .success()
        ])
        let inspections = InventorySequence(inventories: [
            inventory(includesToolchain: false, includesSDK: false),
            inventory(includesToolchain: true, includesSDK: false),
            inventory(includesToolchain: true, includesSDK: true)
        ])
        let events = PreparationEventRecorder()
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            downloadPackage: { _, _ in Issue.record("download must not run") },
            detectSwiftly: { swiftly },
            inspect: { _, _ in try await inspections.next() },
            locateSDK: { _ in URL(filePath: "/tmp/sdk.artifactbundle") },
            revalidate: { _ in }
        )
        var entries: [String: SwiftPMEnvironment.Value] = [
            "PREPARATION_SECRET": .sensitive("private")
        ]
        let values = try SwiftPMEnvironment(entries)
        let snapshot = values.snapshot(inheriting: ["CAPTURED": "initial"])
        let traits = try SwiftPMTraits(["PreparationFeature"], includingDefaults: false)

        let environment = try await preparer.prepare(
            try assessment(requires: [.toolchain, .staticLinuxSDK]),
            swiftPMEnvironment: snapshot,
            swiftPMTraits: traits,
            onEvent: { await events.record($0) }
        )
        entries["PREPARATION_SECRET"] = .sensitive("changed")

        let recorded = await commands.commands
        #expect(await inspections.callCount == 3)
        #expect(environment.swiftPMEnvironment.values["CAPTURED"] == "initial")
        #expect(environment.swiftPMEnvironment.values["PREPARATION_SECRET"] == "private")
        #expect(environment.swiftPMTraits.arguments == traits.arguments)
        #expect(recorded.allSatisfy { $0.environment == nil })
        #expect(recorded.allSatisfy { $0.sensitiveEnvironmentKeys.isEmpty })
        #expect(recorded.allSatisfy { !$0.arguments.contains("--traits") })
        #expect(recorded[0].arguments == ["install", "6.2.1", "--verify", "--assume-yes"])
        #expect(!recorded[0].arguments.contains("--use"))
        #expect(recorded[1].arguments == [
            "run", "swift", "sdk", "install", sdkMetadata.downloadURL.absoluteString,
            "--checksum", sdkMetadata.checksum, "+6.2.1"
        ])
        let observed = await events.commands
        #expect(observed.count == recorded.count)
        for (event, command) in zip(observed, recorded) {
            #expect(event.executable == command.executableURL)
            #expect(event.arguments == command.arguments)
            #expect(event.workingDirectory == command.workingDirectory)
            #expect(event.environment == nil)
        }
    }

    @Test("Custom environment storage reaches toolchain and SDK installation commands")
    func customStorageReachesInstallationCommands() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-CustomPreparation") { directory in
            let storageRoot = directory.appending(path: "swiftly")
            let swiftlyExecutable = storageRoot.appending(path: "bin/swiftly")
            try FileManager.default.createDirectory(
                at: storageRoot.appending(path: "swift-sdks/\(sdk.identifier).artifactbundle"),
                withIntermediateDirectories: true
            )
            try makePreparationTestExecutable(
                at: swiftlyExecutable,
                contents: "#!/bin/sh\nprintf '1.2.3\\n'\n"
            )
            let swiftly = try await SwiftlyInstallation.detect(storage: .directory(storageRoot))
            let plans = PlanRecorder()
            let planCountsAtSDKCommands = CountRecorder()
            let commands = RecordingSubprocessRunner(
                results: [.success(), .success()],
                onRun: { command in
                    if command.arguments.contains("sdk") {
                        await planCountsAtSDKCommands.append(await plans.count)
                    }
                }
            )
            let inspections = InventorySequence(inventories: [
                inventory(includesToolchain: false, includesSDK: false),
                inventory(includesToolchain: true, includesSDK: false),
                inventory(includesToolchain: true, includesSDK: true)
            ])
            let storage = EnvironmentStorage.directory(storageRoot)
            let preparer = EnvironmentPreparer(
                runner: commands,
                assessHost: { .ready },
                detectSwiftly: { swiftly },
                inspect: { _, _ in try await inspections.next() },
                locateSDK: { _ in URL(filePath: "/tmp/sdk.artifactbundle") },
                revalidate: { _ in }
            )

            _ = try await preparer.prepare(
                try assessment(requires: [.toolchain, .staticLinuxSDK], environmentStorage: storage),
                recordRemovalPlan: { plan in await plans.append(plan) }
            )

            let recorded = await commands.commands
            #expect(recorded.count == 2)
            for command in recorded {
                #expect(preparationPath(command.environment?["SWIFTLY_HOME_DIR"]) == preparationPath(storageRoot))
                #expect(preparationPath(command.environment?["SWIFTLY_BIN_DIR"]) == preparationPath(
                    storageRoot.appending(path: "bin")
                ))
                #expect(preparationPath(command.environment?["SWIFTLY_TOOLCHAINS_DIR"]) == preparationPath(
                    storageRoot.appending(path: "toolchains")
                ))
            }
            #expect(recorded[1].arguments.prefix(7) == [
                "run", "swift", "sdk", "install", sdkMetadata.downloadURL.absoluteString,
                "--checksum", sdkMetadata.checksum
            ])
            let sdkPathOption = try #require(recorded[1].arguments.firstIndex(of: "--swift-sdks-path"))
            let sdkPath = try #require(recorded[1].arguments.dropFirst(sdkPathOption + 1).first)
            #expect(URL(filePath: sdkPath).pathComponents == storageRoot.appending(path: "swift-sdks").pathComponents)
            #expect(recorded[1].arguments.suffix(1) == ["+6.2.1"])
            #expect(await plans.values == [
                .toolchain(version, in: storage),
                try .environment(
                    toolchain: version,
                    staticLinuxSDKIdentifier: sdk.identifier,
                    in: storage
                )
            ])
            #expect(await planCountsAtSDKCommands.values == [2])
        }
    }

    @Test("A custom SDK installation failure does not fall back to the standard registry")
    func customSDKInstallationDoesNotFallback() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-CustomPreparation") { directory in
            let storageRoot = directory.appending(path: "swiftly")
            let swiftlyExecutable = storageRoot.appending(path: "bin/swiftly")
            try makePreparationTestExecutable(
                at: swiftlyExecutable,
                contents: "#!/bin/sh\nprintf '1.2.3\\n'\n"
            )
            let storage = EnvironmentStorage.directory(storageRoot)
            let swiftly = try #require(
                try await SwiftlyInstallation.detect(storage: storage)
            )
            let inspections = InventorySequence(inventories: [
                inventory(includesToolchain: true, includesSDK: false)
            ])
            let commands = RecordingSubprocessRunner(
                results: [.failure(standardError: "custom registry failed")]
            )
            let preparer = EnvironmentPreparer(
                runner: commands,
                assessHost: { .ready },
                detectSwiftly: { swiftly },
                inspect: { _, _ in try await inspections.next() },
                revalidate: { _ in }
            )

            await #expect(throws: SwiftlyKitError.swiftlyInstallationFailed("custom registry failed")) {
                try await preparer.prepare(
                    try self.assessment(
                        requires: [.staticLinuxSDK],
                        environmentStorage: storage
                    )
                )
            }

            let recorded = await commands.commands
            #expect(recorded.count == 1)
            #expect(recorded[0].arguments.contains("--swift-sdks-path"))
            #expect(!recorded.contains { $0.arguments.contains("--swift-sdks-path") == false })
        }
    }

    @Test("Custom preparation uses its SDK registry for installation and verification")
    func customPreparationUsesCustomSDKRegistry() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-CustomPreparation") { directory in
            let storageRoot = directory.appending(path: "swiftly")
            let storage = EnvironmentStorage.directory(storageRoot)
            let sdkDirectory = storageRoot.appending(path: "swift-sdks")
            try FileManager.default.createDirectory(
                at: sdkDirectory.appending(path: "\(sdk.identifier).artifactbundle"),
                withIntermediateDirectories: true
            )
            let swiftlyExecutable = storageRoot.appending(path: "bin/swiftly")
            try makePreparationTestExecutable(
                at: swiftlyExecutable,
                contents: "#!/bin/sh\nprintf '1.2.3\\n'\n"
            )
            try makePreparationTestExecutable(at: storageRoot.appending(
                path: "toolchains/swift-6.2.1-RELEASE.xctoolchain/usr/bin/swift"
            ))
            let swiftly = try #require(
                try await SwiftlyInstallation.detect(storage: storage)
            )
            let toolchains = #"{"toolchains":[{"version":{"name":"6.2.1","type":"stable"}}]}"#
            let runner = RecordingSubprocessRunner(results: [
                .success(output: toolchains),
                .success(output: ""),
                .success(),
                .success(output: toolchains),
                .success(output: "\(sdk.identifier)\n")
            ])
            let inspector = InstalledEnvironmentInspector(
                runner: runner,
                isToolchainUsable: { _ in true }
            )
            let preparer = EnvironmentPreparer(
                runner: runner,
                detectSwiftly: { swiftly },
                inspect: { swiftly, toolchain in
                    try await inspector.inspect(
                        swiftly: swiftly,
                        selectedToolchain: toolchain
                    )
                },
                revalidate: { _ in }
            )

            let environment = try await preparer.prepare(
                try self.assessment(
                    requires: [.staticLinuxSDK],
                    environmentStorage: storage
                )
            )

            #expect(environment.environmentStorage == storage)
            let commands = await runner.commands
            #expect(commands.count == 5)
            let initialSDKList = try #require(commands.dropFirst(1).first)
            let installSDK = try #require(commands.dropFirst(2).first)
            let finalSDKList = try #require(commands.dropFirst(4).first)
            #expect(initialSDKList.arguments.prefix(5) == [
                "run", "swift", "sdk", "list", "--swift-sdks-path"
            ])
            let listPath = try #require(initialSDKList.arguments.dropFirst(5).first)
            #expect(URL(filePath: listPath).pathComponents == sdkDirectory.pathComponents)
            #expect(initialSDKList.arguments.suffix(1) == ["+6.2.1"])
            #expect(installSDK.arguments.prefix(7) == [
                "run", "swift", "sdk", "install", sdkMetadata.downloadURL.absoluteString,
                "--checksum", sdkMetadata.checksum
            ])
            let installPathOption = try #require(installSDK.arguments.firstIndex(of: "--swift-sdks-path"))
            let installPath = try #require(installSDK.arguments.dropFirst(installPathOption + 1).first)
            #expect(URL(filePath: installPath).pathComponents == sdkDirectory.pathComponents)
            #expect(installSDK.arguments.suffix(1) == ["+6.2.1"])
            #expect(finalSDKList.arguments == initialSDKList.arguments)
        }
    }

    @Test("Successful installation records a full removal plan")
    func successfulInstallationRecordsFullPlan() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [.success(), .success()])
        let inspections = InventorySequence(inventories: [
            inventory(includesToolchain: false, includesSDK: false),
            inventory(includesToolchain: true, includesSDK: false),
            inventory(includesToolchain: true, includesSDK: true)
        ])
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            detectSwiftly: { swiftly },
            inspect: { _, _ in try await inspections.next() },
            locateSDK: { _ in URL(filePath: "/tmp/sdk.artifactbundle") },
            revalidate: { _ in }
        )

        let plans = PlanRecorder()
        _ = try await preparer.prepare(
            try assessment(requires: [.toolchain, .staticLinuxSDK]),
            recordRemovalPlan: { plan in await plans.append(plan) }
        )

        #expect(await plans.values == [
            .toolchain(version),
            try .environment(toolchain: version, staticLinuxSDKIdentifier: sdk.identifier)
        ])
    }

    @Test("SDK installation on a preexisting toolchain records an SDK-only plan")
    func preexistingToolchainRecordsSDKPlan() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [.success()])
        let inspections = InventorySequence(inventories: [
            inventory(includesToolchain: true, includesSDK: false),
            inventory(includesToolchain: true, includesSDK: true)
        ])
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            detectSwiftly: { swiftly },
            inspect: { _, _ in try await inspections.next() },
            locateSDK: { _ in URL(filePath: "/tmp/sdk.artifactbundle") },
            revalidate: { _ in }
        )

        let plans = PlanRecorder()
        _ = try await preparer.prepare(
            try assessment(requires: [.staticLinuxSDK]),
            recordRemovalPlan: { plan in await plans.append(plan) }
        )

        #expect(await plans.values == [try .staticLinuxSDK(identifier: sdk.identifier)])
    }

    @Test("A recorder refusal prevents the corresponding installation command")
    func recorderRefusalPreventsMutation() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [.success()])
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            detectSwiftly: { swiftly },
            inspect: { _, _ in self.inventory(includesToolchain: false, includesSDK: false) },
            revalidate: { _ in }
        )

        await #expect(throws: EnvironmentPlanRecordingError.self) {
            try await preparer.prepare(
                try assessment(requires: [.toolchain]),
                recordRemovalPlan: { _ in throw RecorderRefusal() }
            )
        }
        #expect(await commands.commands.isEmpty)
    }

    @Test("A widened recorder refusal prevents the SDK command")
    func widenedRecorderRefusalPreventsSDKMutation() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [.success()])
        let inspections = InventorySequence(inventories: [
            inventory(includesToolchain: false, includesSDK: false),
            inventory(includesToolchain: true, includesSDK: false)
        ])
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            detectSwiftly: { swiftly },
            inspect: { _, _ in try await inspections.next() },
            revalidate: { _ in }
        )
        let plans = PlanRecorder()
        let fullPlan = try EnvironmentRemovalPlan.environment(
            toolchain: version,
            staticLinuxSDKIdentifier: sdk.identifier
        )

        await #expect(throws: EnvironmentPlanRecordingError.self) {
            try await preparer.prepare(
                try assessment(requires: [.toolchain, .staticLinuxSDK]),
                recordRemovalPlan: { plan in
                    await plans.append(plan)
                    if plan == fullPlan {
                        throw RecorderRefusal()
                    }
                }
            )
        }

        #expect(await plans.values == [
            .toolchain(version),
            try .environment(toolchain: version, staticLinuxSDKIdentifier: sdk.identifier)
        ])
        #expect(await commands.commands.map(\.arguments) == [
            ["install", "6.2.1", "--verify", "--assume-yes"]
        ])
    }

    @Test("Toolchain command cancellation preserves its plan")
    func toolchainCancellationPreservesPlan() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(
            results: [],
            onRun: { _ in throw CancellationError() }
        )
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            detectSwiftly: { swiftly },
            inspect: { _, _ in self.inventory(includesToolchain: false, includesSDK: false) },
            revalidate: { _ in }
        )

        let plans = PlanRecorder()
        await #expect(throws: CancellationError.self) {
            try await preparer.prepare(
                try assessment(requires: [.toolchain]),
                recordRemovalPlan: { plan in await plans.append(plan) }
            )
        }
        #expect(await plans.values == [.toolchain(version)])
    }

    @Test("SDK command cancellation preserves the full plan")
    func SDKCancellationPreservesPlan() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(
            results: [.success()],
            onRun: { command in
                if command.arguments.contains("sdk") { throw CancellationError() }
            }
        )
        let inspections = InventorySequence(inventories: [
            inventory(includesToolchain: false, includesSDK: false),
            inventory(includesToolchain: true, includesSDK: false)
        ])
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            detectSwiftly: { swiftly },
            inspect: { _, _ in try await inspections.next() },
            revalidate: { _ in }
        )

        let plans = PlanRecorder()
        await #expect(throws: CancellationError.self) {
            try await preparer.prepare(
                try assessment(requires: [.toolchain, .staticLinuxSDK]),
                recordRemovalPlan: { plan in await plans.append(plan) }
            )
        }
        #expect(await plans.values == [
            .toolchain(version),
            try .environment(toolchain: version, staticLinuxSDKIdentifier: sdk.identifier)
        ])
    }

    @Test("Post-command inspection failure preserves its exact mapped error")
    func postCommandInspectionFailurePreservesError() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [.success()])
        let inspections = InspectionErrorSequence()
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            detectSwiftly: { swiftly },
            inspect: { _, _ in try await inspections.next(self.inventory(includesToolchain: false, includesSDK: false)) },
            revalidate: { _ in }
        )

        await #expect(throws: SwiftlyKitError.incompatibleSwiftly) {
            try await preparer.prepare(try assessment(requires: [.toolchain]))
        }
    }

    @Test("Failure before an installation attempt has no removal plan")
    func earlyFailureHasNoPlan() async throws {

        let preparer = EnvironmentPreparer(
            assessHost: { throw SwiftlyKitError.unsupportedHost },
            revalidate: { _ in }
        )

        await #expect(throws: SwiftlyKitError.unsupportedHost) {
            try await preparer.prepare(try assessment(requires: [.toolchain]))
        }
    }

    @Test("Toolchain-only preparation reuses the post-install inventory")
    func toolchainOnlyReusesFinalInventory() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [
            .success()
        ])
        let inspections = InventorySequence(inventories: [
            inventory(includesToolchain: false, includesSDK: false),
            inventory(includesToolchain: true, includesSDK: true)
        ])
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            detectSwiftly: { swiftly },
            inspect: { _, _ in try await inspections.next() },
            locateSDK: { _ in URL(filePath: "/tmp/sdk.artifactbundle") },
            revalidate: { _ in }
        )

        _ = try await preparer.prepare(try assessment(requires: [.toolchain]))

        #expect(await inspections.callCount == 2)
        #expect(await commands.commands.count == 1)
    }

    @Test("SDK installation refreshes inventory before validating preparation")
    func sdkInstallationRefreshesInventory() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [
            .success()
        ])
        let inspections = InventorySequence(inventories: [
            inventory(includesToolchain: true, includesSDK: false),
            inventory(includesToolchain: true, includesSDK: false)
        ])
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            detectSwiftly: { swiftly },
            inspect: { _, _ in try await inspections.next() },
            revalidate: { _ in }
        )

        await #expect(throws: SwiftlyKitError.staleAssessment) {
            try await preparer.prepare(try assessment(requires: [.staticLinuxSDK]))
        }

        #expect(await inspections.callCount == 2)
        #expect(await commands.commands.count == 1)
    }

    @Test("Preparation preserves a toolchain plan when its command fails")
    func failedToolchainInstallationPreservesPlan() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [.failure(standardError: "failed")])
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            detectSwiftly: { swiftly },
            inspect: { _, _ in self.inventory(includesToolchain: false, includesSDK: false) },
            revalidate: { _ in }
        )

        let plans = PlanRecorder()
        await #expect(throws: SwiftlyKitError.swiftlyInstallationFailed("failed")) {
            try await preparer.prepare(
                try assessment(requires: [.toolchain]),
                recordRemovalPlan: { plan in await plans.append(plan) }
            )
        }
        #expect(await plans.values == [.toolchain(version)])
    }

    @Test("Preparation produces a full plan when the toolchain was attempted before SDK installation")
    func failedSDKInstallationPreservesFullPlan() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [.success(), .failure(standardError: "failed")])
        let inspections = InventorySequence(inventories: [
            inventory(includesToolchain: false, includesSDK: false),
            inventory(includesToolchain: true, includesSDK: false)
        ])
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            detectSwiftly: { swiftly },
            inspect: { _, _ in try await inspections.next() },
            revalidate: { _ in }
        )

        let plans = PlanRecorder()
        await #expect(throws: SwiftlyKitError.swiftlyInstallationFailed("failed")) {
            try await preparer.prepare(
                try assessment(requires: [.toolchain, .staticLinuxSDK]),
                recordRemovalPlan: { plan in await plans.append(plan) }
            )
        }
        #expect(await plans.values == [
            .toolchain(version),
            try .environment(toolchain: version, staticLinuxSDKIdentifier: sdk.identifier)
        ])
    }

    @Test("Bootstrap validates trust and uses exact safe installer and init flags")
    func bootstrapCommands() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-EnvironmentPreparation") { temporaryDirectory in
            let installed = SwiftlyInstallation(
                executableURL: temporaryDirectory.appending(path: "home/.swiftly/bin/swiftly")
            )
            let detection = DetectionSequence(values: [nil, installed])
            let commands = RecordingSubprocessRunner(results: [
                .success(output: "Developer ID Installer: Swift Open Source; trusted by the Apple notary service"),
                .success(),
                .success()
            ])
            let events = PreparationEventRecorder()
            let preparer = EnvironmentPreparer(
                homeDirectory: temporaryDirectory.appending(path: "home"),
                temporaryDirectory: temporaryDirectory,
                runner: commands,
                assessHost: { .ready },
                downloadPackage: { source, destination in
                    #expect(source.absoluteString == "https://download.swift.org/swiftly/darwin/swiftly.pkg")
                    try Data("package".utf8).write(to: destination)
                },
                detectSwiftly: { try await detection.next() },
                inspect: { _, _ in self.inventory(includesToolchain: true, includesSDK: true) },
                locateSDK: { _ in URL(filePath: "/tmp/sdk.artifactbundle") },
                revalidate: { _ in }
            )

            _ = try await preparer.prepare(
                try assessment(requires: [.swiftly]),
                onEvent: { await events.record($0) }
            )

            let recorded = await commands.commands
            #expect(recorded[0].executableURL.path(percentEncoded: false) == "/usr/sbin/pkgutil")
            #expect(recorded[0].arguments.first == "--check-signature")
            #expect(recorded[1].arguments.suffix(2) == ["-target", "CurrentUserHomeDirectory"])
            #expect(recorded[2].arguments == [
                "init", "--no-modify-profile", "--skip-install",
                "--quiet-shell-followup", "--assume-yes"
            ])
            let observed = await events.commands
            #expect(observed.count == recorded.count)
            for (event, command) in zip(observed, recorded) {
                #expect(event.executable == command.executableURL)
                #expect(event.arguments == command.arguments)
                #expect(event.workingDirectory == command.workingDirectory)
                #expect(event.environment == command.environment)
            }
        }
    }

    @Test("Custom bootstrap populates its namespace without using the system installer")
    func customBootstrapCommands() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-CustomBootstrap") { directory in
            let storageRoot = directory.appending(path: "swiftly")
            let storage = EnvironmentStorage.directory(storageRoot)
            try FileManager.default.createDirectory(
                at: storageRoot.appending(path: "swift-sdks/\(sdk.identifier).artifactbundle"),
                withIntermediateDirectories: true
            )
            let runner = CustomBootstrapRunner()
            let detectionCalls = Counter()
            let preparer = EnvironmentPreparer(
                homeDirectory: directory.appending(path: "unrelated-home"),
                temporaryDirectory: directory,
                runner: runner,
                assessHost: { .ready },
                downloadPackage: { _, destination in
                    try Data("package".utf8).write(to: destination)
                },
                detectSwiftly: {
                    await detectionCalls.increment()
                    guard await detectionCalls.value > 1 else { return nil }
                    return try await SwiftlyInstallation.detect(storage: storage)
                },
                inspect: { _, _ in
                    self.inventory(includesToolchain: true, includesSDK: true)
                },
                locateSDK: { _ in URL(filePath: "/tmp/sdk.artifactbundle") },
                revalidate: { _ in }
            )

            _ = try await preparer.prepare(
                try assessment(requires: [.swiftly], environmentStorage: storage)
            )

            let commands = await runner.commands
            #expect(commands.allSatisfy {
                $0.executableURL.path(percentEncoded: false) != "/usr/sbin/installer"
            })
            let initialization = try #require(commands.last)
            #expect(initialization.arguments == [
                "init", "--no-modify-profile", "--skip-install",
                "--quiet-shell-followup", "--assume-yes"
            ])
            #expect(preparationPath(initialization.environment?["SWIFTLY_HOME_DIR"]) == preparationPath(storageRoot))
            #expect(preparationPath(initialization.environment?["SWIFTLY_BIN_DIR"]) == preparationPath(
                storageRoot.appending(path: "bin")
            ))
            #expect(preparationPath(initialization.environment?["SWIFTLY_TOOLCHAINS_DIR"]) == preparationPath(
                storageRoot.appending(path: "toolchains")
            ))
            #expect(FileManager.default.isExecutableFile(
                atPath: storageRoot.appending(path: "bin/swiftly").path(percentEncoded: false)
            ))
        }
    }

    @Test(
        "Custom bootstrap fails closed unless the payload has exactly one Swiftly executable",
        arguments: [0, 2]
    )
    func customBootstrapRejectsInvalidExecutableCount(payloadExecutables: Int) async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-CustomBootstrap") { directory in
            let storageRoot = directory.appending(path: "swiftly")
            let storage = EnvironmentStorage.directory(storageRoot)
            let runner = CustomBootstrapRunner(payloadExecutables: payloadExecutables)
            let detectionCalls = Counter()
            let preparer = EnvironmentPreparer(
                homeDirectory: directory.appending(path: "unrelated-home"),
                temporaryDirectory: directory,
                runner: runner,
                assessHost: { .ready },
                downloadPackage: { _, destination in
                    try Data("package".utf8).write(to: destination)
                },
                detectSwiftly: {
                    await detectionCalls.increment()
                    guard await detectionCalls.value > 1 else { return nil }
                    return try await SwiftlyInstallation.detect(storage: storage)
                },
                inspect: { _, _ in
                    self.inventory(includesToolchain: true, includesSDK: true)
                },
                locateSDK: { _ in URL(filePath: "/tmp/sdk.artifactbundle") },
                revalidate: { _ in }
            )

            await #expect(throws: SwiftlyKitError.self) {
                try await preparer.prepare(
                    try self.assessment(requires: [.swiftly], environmentStorage: storage)
                )
            }

            let commands = await runner.commands
            #expect(commands.allSatisfy {
                !$0.arguments.contains("init")
            })
            #expect(!FileManager.default.fileExists(
                atPath: storageRoot.appending(path: "bin/swiftly").path(percentEncoded: false)
            ))
        }
    }

    @Test("Bootstrap rejects unsuccessful downloads before running an installer command")
    func bootstrapRejectsHTTPFailure() async throws {

        let commands = RecordingSubprocessRunner(results: [])
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            downloadPackage: { _, _ in throw EnvironmentPreparationError.invalidHTTPResponse(503) },
            detectSwiftly: { nil },
            revalidate: { _ in }
        )

        await #expect(throws: SwiftlyKitError.networkFailure("Swift.org returned HTTP 503.")) {
            try await preparer.prepare(try assessment(requires: [.swiftly]))
        }
        #expect(await commands.commands.isEmpty)
    }

    @Test("Bootstrap rejects an untrusted package before installation")
    func bootstrapRejectsUntrustedPackage() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-EnvironmentPreparation") { temporaryDirectory in
            let commands = RecordingSubprocessRunner(results: [
                .success(output: "Developer ID Installer: Unrelated Vendor; trusted by macOS")
            ])
            let preparer = EnvironmentPreparer(
                temporaryDirectory: temporaryDirectory,
                runner: commands,
                assessHost: { .ready },
                downloadPackage: { _, destination in
                    try Data("package".utf8).write(to: destination)
                },
                detectSwiftly: { nil },
                revalidate: { _ in }
            )

            await #expect(throws: SwiftlyKitError.integrityCheckFailed(
                "The Swiftly installer signature or Apple trust check failed."
            )) {
                try await preparer.prepare(try assessment(requires: [.swiftly]))
            }

            let recorded = await commands.commands
            #expect(recorded.count == 1)
            #expect(recorded[0].executableURL.path(percentEncoded: false) == "/usr/sbin/pkgutil")
        }
    }

    @Test("Preparation refuses mutations not authorized by the assessment")
    func unauthorizedMutationIsRejected() async throws {

        let swiftly = SwiftlyInstallation(executableURL: URL(filePath: "/tmp/swiftly"))
        let commands = RecordingSubprocessRunner(results: [])
        let preparer = EnvironmentPreparer(
            runner: commands,
            assessHost: { .ready },
            detectSwiftly: { swiftly },
            inspect: { _, _ in self.inventory(includesToolchain: false, includesSDK: false) },
            revalidate: { _ in }
        )

        await #expect(throws: SwiftlyKitError.staleAssessment) {
            try await preparer.prepare(try assessment(requires: []))
        }
        #expect(await commands.commands.isEmpty)
    }

    @Test("Download cancellation remains CancellationError")
    func downloadCancellationIsPreserved() async throws {

        let preparer = EnvironmentPreparer(
            assessHost: { .ready },
            downloadPackage: { _, _ in throw CancellationError() },
            detectSwiftly: { nil },
            revalidate: { _ in }
        )

        await #expect(throws: CancellationError.self) {
            try await preparer.prepare(try assessment(requires: [.swiftly]))
        }
    }

    private func inventory(includesToolchain: Bool, includesSDK: Bool) -> InstalledEnvironmentInventory {

        InstalledEnvironmentInventory(
            toolchains: includesToolchain ? [version] : [],
            sdks: includesSDK ? [InstalledStaticLinuxSDK(
                toolchainVersion: version,
                identifier: sdk.identifier
            )] : []
        )
    }

    private func assessment(
        requires components: [PreparationComponent],
        environmentStorage: EnvironmentStorage = .standard
    ) throws -> EnvironmentAssessment {

        try withTemporaryDirectory(prefix: "SwiftlyKit-EnvironmentAssessment") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8)
                .write(to: packageRoot.appending(path: "Package.swift"))

            return EnvironmentAssessment(
                packageInputs: try PackageInputSnapshot.capture(at: packageRoot),
                release: OfficialStableRelease(
                    version: version,
                    staticLinuxSDK: sdk,
                    staticLinuxSDKMetadata: sdkMetadata
                ),
                requiredComponents: components,
                target: .linux(.arm64),
                environmentStorage: environmentStorage
            )
        }
    }

}

private actor PlanRecorder {

    private(set) var values: [EnvironmentRemovalPlan] = []

    var count: Int { values.count }

    func append(_ plan: EnvironmentRemovalPlan) {
        values.append(plan)
    }

}

private actor PreparationEventRecorder {

    private(set) var commands: [CommandInvocation] = []

    func record(_ event: SwiftlyKitEvent) {
        switch event {
            case .progress, .output:
                break
            case .command(let command):
                commands.append(command)
        }
    }

}

private actor CountRecorder {

    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }

}

private struct RecorderRefusal: Error {

}

private actor Counter {

    private(set) var value = 0

    func increment() { value += 1 }

}

private actor InventorySequence {

    var inventories: [InstalledEnvironmentInventory]
    private(set) var callCount = 0

    init(inventories: [InstalledEnvironmentInventory]) {
        self.inventories = inventories
    }

    func next() throws -> InstalledEnvironmentInventory {
        callCount += 1
        guard !inventories.isEmpty else { throw PreparationTestFailure.missingFixture }
        return inventories.removeFirst()
    }

}

private actor InspectionErrorSequence {

    private var isFirst = true

    func next(_ initial: InstalledEnvironmentInventory) throws -> InstalledEnvironmentInventory {
        if isFirst {
            isFirst = false
            return initial
        }
        throw InstalledEnvironmentError.invalidOutput
    }

}

private actor DetectionSequence {

    var values: [SwiftlyInstallation?]

    init(values: [SwiftlyInstallation?]) {
        self.values = values
    }

    func next() throws -> SwiftlyInstallation? {
        guard !values.isEmpty else { throw PreparationTestFailure.missingFixture }
        return values.removeFirst()
    }

}

private enum PreparationTestFailure: Error {
    case missingFixture
}

private func makePreparationTestExecutable(at url: URL, contents: String = "#!/bin/sh\nexit 0\n") throws {

    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path(percentEncoded: false)
    )
}

private func preparationPath(_ value: String?) -> String {

    guard let value else { return "" }
    let path = URL(filePath: value).standardizedFileURL
        .path(percentEncoded: false)
    let normalized = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    guard normalized != "/" else { return normalized }
    return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
}

private func preparationPath(_ value: URL) -> String {

    preparationPath(value.path(percentEncoded: false))
}

private actor CustomBootstrapRunner: SubprocessRunning {

    private(set) var commands: [SubprocessCommand] = []
    private let payloadExecutables: Int

    init(payloadExecutables: Int = 1) {
        self.payloadExecutables = payloadExecutables
    }

    func run(_ command: SubprocessCommand, onOutput: SubprocessOutputHandler?) async throws -> SubprocessResult {

        commands.append(command)
        let arguments = command.arguments

        if arguments.first == "--expand-full" {
            let expanded = URL(filePath: arguments[2])
            for index in 0..<payloadExecutables {
                let package = index == 0 ? "SwiftlyInstaller.pkg" : "AdditionalInstaller.pkg"
                let payload = expanded.appending(path: "\(package)/Payload")
                let executable = payload.appending(path: "bin/swiftly")
                try makePreparationTestExecutable(
                    at: executable,
                    contents: "#!/bin/sh\nprintf '1.2.3\\n'\n"
                )
            }
            return .success()
        }

        if command.executableURL.path(percentEncoded: false) == "/usr/sbin/pkgutil" {
            return .success(
                output: "Developer ID Installer: Swift Open Source; trusted by the Apple notary service"
            )
        }

        return .success()
    }

}
