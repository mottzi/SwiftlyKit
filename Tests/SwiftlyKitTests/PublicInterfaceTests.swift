import Foundation
import SwiftlyKit
import Testing

@Suite("Public interface")
struct PublicInterfaceTests {

    @Test("The documented workflow compiles without testable access")
    func documentedWorkflowCompiles() {
        let workflow: @Sendable (URL) async throws -> URL = documentedWorkflow
        _ = workflow
    }

    @Test("The fast-track workflow compiles with every default")
    func fastTrackWorkflowCompiles() {

        let workflow: @Sendable (URL) async throws -> URL = { packageRoot in
            try await SwiftlyKit.build(packageRoot)
        }
        _ = workflow
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

    @Test("The fast-track SwiftPM environment workflow compiles without testable access")
    func fastTrackSwiftPMEnvironmentCompiles() {

        let workflow: @Sendable (URL, String) async throws -> URL = { packageRoot, token in
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

    @Test("Package traits compile in staged and fast-track workflows")
    func swiftPMTraitsCompile() {

        let selection: ([String], Bool) throws(SwiftlyKitError) -> SwiftPMTraits = { names, includingDefaults in
            try SwiftPMTraits(names, includingDefaults: includingDefaults)
        }
        let staged: @Sendable (EnvironmentAssessment) async throws -> LocalBuildEnvironment = { assessment in
            let traits = try SwiftPMTraits(["Production"], includingDefaults: true)
            return try await SwiftlyKit().prepare(assessment, swiftPMTraits: traits)
        }
        let fastTrack: @Sendable (URL) async throws -> URL = { packageRoot in
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

        let workflow: @Sendable (URL, URL) async throws -> URL = { packageRoot, destination in
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
        let fastTrack: @Sendable (URL) async throws -> URL = { packageRoot in
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

        let workflow: @Sendable (URL, LocalBuildEnvironment, ExecutableProduct, URL) async throws -> URL = {
            packageRoot, environment, product, destination in
            let kit = SwiftlyKit()
            let storage = BuildStorage.directory(packageRoot.appending(path: "scratch"))
            let request = BuildRequest(
                product,
                storage: storage,
                output: .publish(to: destination, cleanup: .reset)
            )
            let executable = try await kit.build(request, using: environment)
            try await kit.cleanBuildArtifacts(in: storage, using: environment)
            try await kit.resetBuildStorage(in: storage, using: environment)
            return executable
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

private func documentedWorkflow(_ packageRoot: URL) async throws -> URL {

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
        try await kit.resolveDependencies(using: environment)
        return try await kit.build(request, using: environment)
    }
}
