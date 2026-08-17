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
            swiftPMTraits: traits
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

            _ = try await preparer.prepare(try assessment(requires: [.swiftly]))

            let recorded = await commands.commands
            #expect(recorded[0].executableURL.path(percentEncoded: false) == "/usr/sbin/pkgutil")
            #expect(recorded[0].arguments.first == "--check-signature")
            #expect(recorded[1].arguments.suffix(2) == ["-target", "CurrentUserHomeDirectory"])
            #expect(recorded[2].arguments == [
                "init", "--no-modify-profile", "--skip-install",
                "--quiet-shell-followup", "--assume-yes"
            ])
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

    private func assessment(requires components: [PreparationComponent]) throws -> EnvironmentAssessment {

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
                target: .linux(.arm64)
            )
        }
    }

}

private actor PlanRecorder {

    private(set) var values: [EnvironmentRemovalPlan] = []

    func append(_ plan: EnvironmentRemovalPlan) {
        values.append(plan)
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
