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
