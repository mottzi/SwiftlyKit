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

    @Test("The documented Command Line Tools recovery compiles without testable access")
    func commandLineToolsRecoveryCompiles() {

        let recovery: @Sendable () async throws -> Void = {
            try await SwiftlyKit.requestCommandLineToolsInstallation()
        }
        _ = recovery
    }

    @Test("Build storage copying and cleanup compile without testable access")
    func buildStorageLifecycleCompiles() {

        let workflow: @Sendable (URL, LocalBuildEnvironment, ExecutableProduct, URL) async throws -> URL = {
            packageRoot, environment, product, destination in
            let kit = SwiftlyKit()
            let storage = BuildStorage.directory(packageRoot.appending(path: "scratch"))
            let request = BuildRequest(
                product,
                storage: storage,
                output: .copy(to: destination, cleanup: .reset)
            )
            let executable = try await kit.build(request, using: environment)
            try await kit.cleanBuildArtifacts(in: storage, using: environment)
            try await kit.resetBuildStorage(in: storage, using: environment)
            return executable
        }
        _ = workflow
    }

}

private func documentedWorkflow(_ packageRoot: URL) async throws -> URL {

    let kit = SwiftlyKit()
    let assessment = try await kit.assess(packageRoot, for: .linux(.arm64))
    _ = assessment.requiresInstallation
    let environment = try await kit.prepare(assessment)
    let products = try await kit.executableProducts(using: environment)
    guard let product = products.first else { throw SwiftlyKitError.executableProductNotFound("") }
    let request = BuildRequest(product, configuration: .release)
    do {
        return try await kit.build(request, using: environment)
    } catch SwiftlyKitError.dependencyResolutionRequired {
        try await kit.resolveDependencies(using: environment)
        return try await kit.build(request, using: environment)
    }
}
