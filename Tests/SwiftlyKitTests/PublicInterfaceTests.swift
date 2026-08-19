import Foundation
import SwiftlyKit
import Testing

@Suite("Public client compile checks")
struct PublicInterfaceTests {

    @Test("Convenience and staged workflows compile without testable access")
    func workflowsCompile() {

        let convenienceDefaults: @Sendable (URL) async throws -> BuildResult = {
            try await SwiftlyKit.build($0)
        }
        let configured: @Sendable (URL, URL, String) async throws -> BuildResult = configuredWorkflow
        let staged: @Sendable (URL, URL) async throws -> BuildResult = stagedWorkflow
        let assessment: @Sendable (URL) async throws -> EnvironmentAssessment = {
            try await SwiftlyKit().assess($0, for: .linux(.arm64))
        }
        let hostRecovery: @Sendable () async throws -> Void = {
            _ = try await SwiftlyKit.hostReadiness()
            try await SwiftlyKit.requestCommandLineToolsInstallation()
        }

        _ = convenienceDefaults
        _ = configured
        _ = staged
        _ = assessment
        _ = hostRecovery
    }

    @Test("Public build and removal values compile without testable access")
    func valuesCompile() throws {

        let version = try #require(SwiftVersion("6.3.3"))
        let losslessVersion: any LosslessStringConvertible = version
        let storage = EnvironmentStorage.directory(URL(filePath: "/tmp/swiftlykit-environment"))
        let plans = [
            EnvironmentRemovalPlan.toolchain(version, in: storage),
            try EnvironmentRemovalPlan.staticLinuxSDK(
                identifier: "swift-6.3.3-RELEASE_static-linux-0.1.0",
                in: storage
            ),
            try EnvironmentRemovalPlan.environment(
                toolchain: version,
                staticLinuxSDKIdentifier: "swift-6.3.3-RELEASE_static-linux-0.1.0",
                in: storage
            )
        ]
        let encoded = try JSONEncoder().encode(plans[2])
        let decoded = try JSONDecoder().decode(EnvironmentRemovalPlan.self, from: encoded)
        for resource in decoded.resources {
            switch resource {
                case .toolchain(let toolchain): _ = toolchain
                case .staticLinuxSDK(let identifier): _ = identifier
                @unknown default: break
            }
        }

        let request: @Sendable (ExecutableProduct, URL) -> BuildRequest = { product, destination in
            BuildRequest(
                product,
                configuration: .release,
                jobs: 2,
                scratchStorage: .directory(
                    destination.deletingLastPathComponent().appending(path: "scratch")
                ),
                output: .publish(to: destination, replacingExisting: true, cleanup: .reset),
                strip: true
            )
        }
        let remove: @Sendable (EnvironmentRemovalPlan) async throws -> Void = {
            try await SwiftlyKit.remove($0, onEvent: observe)
        }

        _ = losslessVersion
        _ = decoded.storage
        _ = request
        _ = remove
        _ = SwiftPMSharedStorage.standard
        _ = SwiftPMScratchStorage.packageDefault
        _ = SwiftPMTraits.packageDefaults
        _ = SwiftPMTraits.none
        _ = SwiftPMTraits.all
    }

}

private func configuredWorkflow(packageRoot: URL, destination: URL, token: String) async throws -> BuildResult {

    let stateRoot = destination.deletingLastPathComponent().appending(path: "SwiftlyKitState")
    let storageRoot = stateRoot.appending(path: "swiftly")
    let sharedRoot = stateRoot.appending(path: "shared")
    return try await SwiftlyKit.build(
        packageRoot,
        product: "Tool",
        for: .linux(.arm64),
        toolchain: .exact(SwiftVersion(major: 6, minor: 3, patch: 3)),
        configuration: .release,
        jobs: 2,
        scratchStorage: .directory(stateRoot.appending(path: "scratch")),
        output: .publish(to: destination, replacingExisting: true, cleanup: .reset),
        strip: true,
        swiftPMEnvironment: try SwiftPMEnvironment([
            "PACKAGE_FLAVOR": .plain("production"),
            "SWIFTPM_REGISTRY_TOKEN": .sensitive(token),
            "UNWANTED_PARENT_VALUE": .unset
        ]),
        swiftPMTraits: try SwiftPMTraits(["Production"], includingDefaults: true),
        swiftPMSharedStorage: SwiftPMSharedStorage(
            cacheDirectory: sharedRoot.appending(path: "cache"),
            configurationDirectory: sharedRoot.appending(path: "configuration"),
            securityDirectory: sharedRoot.appending(path: "security")
        ),
        environmentStorage: .directory(storageRoot),
        recordRemovalPlan: { _ in },
        onEvent: observe
    )
}

private func stagedWorkflow(packageRoot: URL, destination: URL) async throws -> BuildResult {

    let kit = SwiftlyKit(environmentStorage: .standard)
    let choices = try await kit.compatibleEnvironments(packageRoot, for: .linux(.x86_64))
    _ = choices.map(\.swiftVersion)
    let assessment = try choices.select(.automatic)
    _ = assessment.packageRoot
    _ = assessment.toolsVersion
    _ = assessment.staticLinuxSDK
    _ = assessment.isSwiftlyAvailable
    _ = assessment.isToolchainAvailable
    _ = assessment.isStaticLinuxSDKAvailable
    _ = assessment.requiresInstallation

    let environment = try await kit.prepare(
        assessment,
        swiftPMEnvironment: try SwiftPMEnvironment(),
        swiftPMTraits: .packageDefaults,
        swiftPMSharedStorage: .standard,
        recordRemovalPlan: { _ in },
        onEvent: observe
    )
    let products = try await kit.executableProducts(using: environment)
    let product = try products.select()
    let scratch: SwiftPMScratchStorage = .directory(
        destination.deletingLastPathComponent().appending(path: "scratch")
    )
    let request = BuildRequest(
        product,
        scratchStorage: scratch,
        output: .publish(to: destination)
    )

    let result: BuildResult
    do {
        result = try await kit.build(request, using: environment, onEvent: observe)
    } catch SwiftlyKitError.dependencyResolutionRequired {
        try await kit.resolveDependencies(in: scratch, using: environment, onEvent: observe)
        result = try await kit.build(request, using: environment, onEvent: observe)
    }

    _ = result.executable
    _ = result.resourceBundles
    _ = result.directory
    try await kit.cleanBuildArtifacts(in: scratch, using: environment, onEvent: observe)
    try await kit.resetBuildStorage(in: scratch, using: environment, onEvent: observe)
    return result
}

private func observe(_ event: SwiftlyKitEvent) async {

    switch event {
        case .progress(let progress):
            if case let .preparingEnvironment(component, step) = progress.operation {
                _ = component
                _ = step
            }
            _ = progress.detail

        case .command(let command):
            _ = command.executable
            _ = command.arguments
            _ = command.workingDirectory
            _ = command.environment

        case .output(let output):
            _ = output.stream
            _ = output.text

        @unknown default:
            break
    }
}
