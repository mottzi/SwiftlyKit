import Foundation
import SwiftlyKit
import Testing

@Suite("Public interface")
struct PublicInterfaceTests {

    @Test("The documented workflow compiles without testable access")
    func documentedWorkflowCompiles() {
        let workflow: @Sendable (URL) async throws -> BuildResult = documentedWorkflow
        _ = workflow
    }

    @Test("The fast-track workflow compiles with every default")
    func fastTrackWorkflowCompiles() {

        let workflow: @Sendable (URL) async throws -> BuildResult = { packageRoot in
            try await SwiftlyKit.build(packageRoot)
        }
        _ = workflow
    }

    @Test("Environment storage compiles in staged, fast-track, and removal workflows")
    func environmentStorageCompiles() {

        let storage = EnvironmentStorage.directory(URL(filePath: "/tmp/swiftlykit-swiftly"))
        let kit = SwiftlyKit(environmentStorage: storage)
        let staged: @Sendable (EnvironmentAssessment) async throws -> LocalBuildEnvironment = { assessment in
            try await kit.prepare(assessment)
        }
        let fastTrack: @Sendable (URL) async throws -> BuildResult = { packageRoot in
            try await SwiftlyKit.build(packageRoot, environmentStorage: storage)
        }
        let removal = EnvironmentRemovalPlan.toolchain(
            SwiftVersion(major: 6, minor: 3, patch: 3),
            in: storage
        )

        _ = EnvironmentStorage.standard
        _ = staged
        _ = fastTrack
        _ = removal
    }

    @Test("The staged SwiftPM environment workflow compiles without testable access")
    func stagedSwiftPMEnvironmentCompiles() {

        let workflow: @Sendable (EnvironmentAssessment, String) async throws -> LocalBuildEnvironment = {
            assessment, token in
            let values = try SwiftPMEnvironment([
                "PACKAGE_FLAVOR": .plain("production"),
                "SWIFTPM_REGISTRY_TOKEN": .sensitive(token),
                "UNWANTED_PARENT_VALUE": .unset
            ])
            return try await SwiftlyKit().prepare(
                assessment,
                swiftPMEnvironment: values
            )
        }
        _ = workflow
    }

    @Test("Environment preparation and removal plans compile without testable access")
    func environmentLifecycleCompiles() {

        let plans: @Sendable (EnvironmentAssessment) throws -> [EnvironmentRemovalPlan] = { assessment in
            let plans = [
                EnvironmentRemovalPlan.toolchain(assessment.swiftVersion),
                try EnvironmentRemovalPlan.staticLinuxSDK(identifier: assessment.staticLinuxSDK.identifier),
                try EnvironmentRemovalPlan.environment(
                    toolchain: assessment.swiftVersion,
                    staticLinuxSDKIdentifier: assessment.staticLinuxSDK.identifier
                )
            ]
            let data = try JSONEncoder().encode(plans[2])
            _ = try JSONDecoder().decode(EnvironmentRemovalPlan.self, from: data)
            return plans
        }

        let staged: @Sendable (EnvironmentAssessment) async throws -> LocalBuildEnvironment = { assessment in
            try await SwiftlyKit().prepare(assessment)
        }

        let remove: @Sendable (EnvironmentRemovalPlan) async throws -> Void = { plan in
            try await SwiftlyKit.remove(plan)
        }

        _ = plans
        _ = staged
        _ = remove
    }

    @Test("Removal-plan recording compiles in staged and fast-track workflows")
    func removalPlanRecordingCompiles() {

        let recorder: EnvironmentRemovalPlan.Recorder = { plan in
            _ = plan
        }
        let staged: @Sendable (EnvironmentAssessment) async throws -> LocalBuildEnvironment = { assessment in
            try await SwiftlyKit().prepare(assessment, recordRemovalPlan: recorder)
        }
        let fastTrack: @Sendable (URL) async throws -> BuildResult = { packageRoot in
            try await SwiftlyKit.build(packageRoot, recordRemovalPlan: recorder)
        }

        _ = staged
        _ = fastTrack
    }

    @Test("The fast-track SwiftPM environment workflow compiles without testable access")
    func fastTrackSwiftPMEnvironmentCompiles() {

        let workflow: @Sendable (URL, String) async throws -> BuildResult = { packageRoot, token in
            try await SwiftlyKit.build(
                packageRoot,
                swiftPMEnvironment: try SwiftPMEnvironment([
                    "PKG_CONFIG_PATH": .plain("/opt/linux/lib/pkgconfig"),
                    "SWIFTPM_REGISTRY_TOKEN": .sensitive(token)
                ])
            )
        }
        _ = workflow
    }

    @Test("Structured command observation compiles without testable access")
    func structuredCommandObservationCompiles() {

        let observer: SwiftlyKitEvent.Handler = { event in
            switch event {
                case .progress, .output:
                    break
                case .command(let command):
                    _ = command.executable
                    _ = command.arguments
                    _ = command.workingDirectory
                    _ = command.environment
                @unknown default:
                    break
            }
        }
        let staged: @Sendable (EnvironmentAssessment) async throws -> LocalBuildEnvironment = { assessment in
            try await SwiftlyKit().prepare(assessment, onEvent: observer)
        }
        let fastTrack: @Sendable (URL) async throws -> BuildResult = { packageRoot in
            try await SwiftlyKit.build(packageRoot, onEvent: observer)
        }

        _ = staged
        _ = fastTrack
    }

    @Test("Semantic preparation progress compiles without testable access")
    func semanticPreparationProgressCompiles() {

        let observer: SwiftlyKitEvent.Handler = { event in
            switch event {
                case .progress(let progress):
                    if case let .preparingEnvironment(component, step) = progress.operation {
                        _ = component
                        _ = step
                    }
                    _ = progress.detail

                case .command, .output:
                    break

                @unknown default:
                    break
            }
        }

        _ = observer
    }

    @Test("SwiftPM shared and scratch storage compile in staged and fast-track workflows")
    func swiftPMStorageCompiles() {

        let cacheDirectory = URL(filePath: "/tmp/swiftlykit-cache")
        let configurationDirectory = URL(filePath: "/tmp/swiftlykit-configuration")
        let securityDirectory = URL(filePath: "/tmp/swiftlykit-security")
        let partial = SwiftPMSharedStorage(cacheDirectory: cacheDirectory)
        let complete = SwiftPMSharedStorage(
            cacheDirectory: cacheDirectory,
            configurationDirectory: configurationDirectory,
            securityDirectory: securityDirectory
        )

        let staged: @Sendable (EnvironmentAssessment, SwiftPMSharedStorage) async throws -> LocalBuildEnvironment = {
            assessment, sharedStorage in
            try await SwiftlyKit().prepare(
                assessment,
                swiftPMSharedStorage: sharedStorage
            )
        }
        let resolution: @Sendable (LocalBuildEnvironment, SwiftPMScratchStorage) async throws -> Void = {
            environment, scratchStorage in
            try await SwiftlyKit().resolveDependencies(
                in: scratchStorage,
                using: environment
            )
        }
        let request: @Sendable (ExecutableProduct) -> BuildRequest = { product in
            BuildRequest(
                product,
                scratchStorage: .directory(URL(filePath: "/tmp/swiftlykit-scratch"))
            )
        }
        let fastTrack: @Sendable (URL, SwiftPMSharedStorage, SwiftPMScratchStorage) async throws -> BuildResult = {
            packageRoot, sharedStorage, scratchStorage in
            try await SwiftlyKit.build(
                packageRoot,
                scratchStorage: scratchStorage,
                swiftPMSharedStorage: sharedStorage
            )
        }

        _ = SwiftPMSharedStorage.standard
        _ = partial
        _ = complete
        _ = staged
        _ = resolution
        _ = request
        _ = fastTrack
    }

    @Test("Package traits compile in staged and fast-track workflows")
    func swiftPMTraitsCompile() {

        let selection: ([String], Bool) throws(SwiftlyKitError) -> SwiftPMTraits = { names, includingDefaults in
            try SwiftPMTraits(names, includingDefaults: includingDefaults)
        }
        let staged: @Sendable (EnvironmentAssessment) async throws -> LocalBuildEnvironment = { assessment in
            let traits = try SwiftPMTraits(["Production"], includingDefaults: true)
            return try await SwiftlyKit().prepare(assessment, swiftPMTraits: traits)
        }
        let fastTrack: @Sendable (URL) async throws -> BuildResult = { packageRoot in
            try await SwiftlyKit.build(
                packageRoot,
                swiftPMTraits: try SwiftPMTraits(["Production"], includingDefaults: false)
            )
        }

        _ = selection
        _ = staged
        _ = fastTrack
        _ = SwiftPMTraits.packageDefaults
        _ = SwiftPMTraits.none
        _ = SwiftPMTraits.all
    }

    @Test("The fast track exposes exact toolchain selection and stripping")
    func fastTrackToolchainAndStrippingCompile() {

        let workflow: @Sendable (URL, URL) async throws -> BuildResult = { packageRoot, destination in
            try await SwiftlyKit.build(
                packageRoot,
                toolchain: .exact(SwiftVersion(major: 6, minor: 2, patch: 1)),
                output: .publish(to: destination),
                strip: true
            )
        }
        _ = workflow
    }

    @Test("Concurrent build job limits compile in staged and fast-track workflows")
    func buildJobsCompile() {

        let staged: @Sendable (ExecutableProduct) -> BuildRequest = { product in
            BuildRequest(product, jobs: 2)
        }
        let fastTrack: @Sendable (URL) async throws -> BuildResult = { packageRoot in
            try await SwiftlyKit.build(packageRoot, jobs: 2)
        }

        _ = staged
        _ = fastTrack
    }

    @Test("Compatible environment discovery compiles without testable access")
    func compatibleEnvironmentDiscoveryCompiles() {

        let workflow: @Sendable (URL, ToolchainSelection) async throws -> EnvironmentAssessment = {
            packageRoot, selection in
            let choices = try await SwiftlyKit().compatibleEnvironments(
                packageRoot,
                for: .linux(.arm64)
            )
            _ = choices.map(\.swiftVersion)
            return try choices.select(selection)
        }
        _ = workflow
    }

    @Test("Host readiness inspection compiles without testable access")
    func hostReadinessInspectionCompiles() {

        let inspection: @Sendable () async throws -> HostReadiness = {
            try await SwiftlyKit.hostReadiness()
        }
        _ = inspection
    }

    @Test("Swift version text conversion compiles without testable access")
    func swiftVersionTextConversionCompiles() {

        let version = SwiftVersion("6.3.3")
        let losslessVersion: (any LosslessStringConvertible)? = version
        _ = losslessVersion
    }

    @Test("The documented Command Line Tools recovery compiles without testable access")
    func commandLineToolsRecoveryCompiles() {

        let recovery: @Sendable () async throws -> Void = {
            try await SwiftlyKit.requestCommandLineToolsInstallation()
        }
        _ = recovery
    }

    @Test("Build output publication and cleanup compile without testable access")
    func buildStorageLifecycleCompiles() {

        let workflow: @Sendable (URL, LocalBuildEnvironment, ExecutableProduct, URL) async throws -> BuildResult = {
            packageRoot, environment, product, destination in
            let kit = SwiftlyKit()
            let scratchStorage = SwiftPMScratchStorage.directory(packageRoot.appending(path: "scratch"))
            let request = BuildRequest(
                product,
                scratchStorage: scratchStorage,
                output: .publish(to: destination, cleanup: .reset)
            )
            let result = try await kit.build(request, using: environment)
            _ = result.executable
            _ = result.resourceBundles
            _ = result.directory
            try await kit.cleanBuildArtifacts(in: scratchStorage, using: environment)
            try await kit.resetBuildStorage(in: scratchStorage, using: environment)
            return result
        }
        _ = workflow
    }

    @Test("Atomic output replacement compiles without testable access")
    func outputReplacementCompiles() {

        let output: @Sendable (URL) -> BuildOutput = { destination in
            .publish(to: destination, replacingExisting: true, cleanup: .reset)
        }
        _ = output
    }

}

private func documentedWorkflow(_ packageRoot: URL) async throws -> BuildResult {

    let kit = SwiftlyKit()
    let assessment = try await kit.assess(packageRoot, for: .linux(.arm64))
    _ = assessment.requiresInstallation
    let environment = try await kit.prepare(assessment)
    let products = try await kit.executableProducts(using: environment)
    let product = try products.select()
    let request = BuildRequest(product, configuration: .release)
    do {
        return try await kit.build(request, using: environment)
    } catch SwiftlyKitError.dependencyResolutionRequired {
        try await kit.resolveDependencies(in: request.scratchStorage, using: environment)
        return try await kit.build(request, using: environment)
    }
}
