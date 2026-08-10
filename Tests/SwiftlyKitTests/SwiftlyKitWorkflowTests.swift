import Foundation
import Testing
@testable import SwiftlyKit

@Suite("SwiftlyKit workflow")
struct SwiftlyKitWorkflowTests {

    @Test("Preparation rejects package inputs changed after assessment")
    func staleAssessment() async throws {

        try await withWorkflowTemporaryDirectory { packageRoot in
            let manifestURL = packageRoot.appending(path: "Package.swift")
            let originalManifest = Data("// swift-tools-version: 6.0\n".utf8)
            try originalManifest.write(to: manifestURL)
            let version = SwiftVersion(major: 6, minor: 2, patch: 1)
            let requirements = try PackageRequirements.load(at: packageRoot)
            let assessment = EnvironmentAssessment(
                packageInputs: try PackageInputSnapshot.capture(requirements),
                release: OfficialStableRelease(
                    version: version,
                    staticLinuxSDK: OfficialStaticLinuxSDK(
                        version: "1.0.0",
                        identifier: "sdk",
                        downloadURL: URL(string: "https://download.swift.org/sdk.tar.gz")!,
                        checksum: String(repeating: "a", count: 64),
                        supportedArchitectures: [.arm64]
                    )
                ),
                requiredComponents: [],
                target: .linux(.arm64)
            )
            let kit = SwiftlyKit(
                assessor: EnvironmentAssessor(),
                preparer: EnvironmentPreparer(
                    checkHost: {},
                    detectSwiftly: { Issue.record("detection must follow revalidation"); return nil }
                ),
                swiftPM: SwiftPM()
            )
            try Data("// swift-tools-version: 6.0\n// changed\n".utf8).write(to: manifestURL)

            await #expect(throws: SwiftlyKitError.staleAssessment) {
                try await kit.prepare(assessment)
            }

            try originalManifest.write(to: manifestURL)
            try Data("6.2.1\n".utf8).write(to: packageRoot.appending(path: ".swift-version"))
            await #expect(throws: SwiftlyKitError.staleAssessment) {
                try await kit.prepare(assessment)
            }
        }
    }

    @Test("A prepared capability carries package and target context into product discovery")
    func capabilityDrivenProductDiscovery() async throws {

        try await withWorkflowTemporaryDirectory { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            let version = SwiftVersion(major: 6, minor: 2, patch: 1)
            let sdkIdentifier = "swift-6.2.1-RELEASE_static-linux-0.0.1"
            let sdkBundle = packageRoot.appending(path: "\(sdkIdentifier).artifactbundle")
            let swiftly = SwiftlyInstallation(
                executableURL: packageRoot.appending(path: "swiftly")
            )
            let inventory = InstalledEnvironmentInventory(
                toolchains: [version],
                sdks: [InstalledStaticLinuxSDK(
                    toolchainVersion: version,
                    identifier: sdkIdentifier
                )]
            )
            let release = OfficialStableRelease(
                version: version,
                staticLinuxSDK: OfficialStaticLinuxSDK(
                    version: "0.0.1",
                    identifier: sdkIdentifier,
                    downloadURL: URL(string: "https://download.swift.org/sdk.tar.gz")!,
                    checksum: String(repeating: "a", count: 64),
                    supportedArchitectures: [.arm64]
                )
            )
            let runner = RecordingSubprocessRunner(results: [SubprocessResult(
                succeeded: true,
                standardOutput: """
                    {"products":[{"name":"Tool","targets":["Tool"],"type":{"executable":null}}],
                     "targets":[{"name":"Tool","type":"executable","dependencies":[],"resources":[]}]}
                    """,
                standardError: ""
            )])
            let kit = SwiftlyKit(
                assessor: EnvironmentAssessor(
                    checkHost: {},
                    detectSwiftly: { swiftly },
                    loadReleases: { [release] },
                    inspectInventory: { _ in inventory },
                    locateSDK: { _ in sdkBundle }
                ),
                preparer: EnvironmentPreparer(
                    runner: runner,
                    checkHost: {},
                    downloadPackage: { _, _ in Issue.record("download must not run"); return 200 },
                    detectSwiftly: { swiftly },
                    inspect: { _, _ in inventory },
                    locateSDK: { _ in sdkBundle }
                ),
                swiftPM: SwiftPM(
                    runner: runner,
                    validateEnvironment: { _ in }
                )
            )

            let assessment = try await kit.assess(packageRoot, for: .linux(.arm64))
            let environment = try await kit.prepare(assessment)
            let products = try await kit.executableProducts(using: environment)

            #expect(!assessment.requiresInstallation)
            #expect(assessment.isSwiftlyAvailable)
            #expect(assessment.isToolchainAvailable)
            #expect(assessment.isStaticLinuxSDKAvailable)
            #expect(environment.swiftVersion == version)
            #expect(products.map(\.name) == ["Tool"])
        }
    }

    @Test("Public mutating workflows share one instance-level gate")
    func mutatingWorkflowsAreSerialized() async throws {

        try await withWorkflowTemporaryDirectory { packageRoot in
            let executable = packageRoot.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let runner = WorkflowMutationRunner(binaryDirectory: packageRoot)
            let kit = SwiftlyKit(
                assessor: EnvironmentAssessor(),
                preparer: EnvironmentPreparer(),
                swiftPM: SwiftPM(
                    runner: runner,
                    validateEnvironment: { _ in }
                )
            )
            let environment = LocalBuildEnvironment(
                swiftVersion: SwiftVersion(major: 6, minor: 2, patch: 1),
                staticLinuxSDK: StaticLinuxSDK(identifier: "sdk", version: "1.0.0"),
                packageRoot: packageRoot,
                swiftlyExecutableURL: URL(filePath: "/swiftly"),
                sdkBundleURL: packageRoot.appending(path: "sdk.artifactbundle"),
                target: .linux(.arm64)
            )

            async let resolution: Void = kit.resolveDependencies(using: environment)
            async let build = kit.build(
                BuildRequest(ExecutableProduct(name: "Tool")),
                using: environment
            )
            let (_, built) = try await (resolution, build)

            #expect(built == executable)
            #expect(await runner.maximumConcurrentCommands == 1)
        }
    }

}

private func withWorkflowTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SwiftlyKit-Workflow-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

private actor WorkflowMutationRunner: SubprocessRunning {

    private let binaryDirectory: URL
    private var concurrentCommands = 0
    private(set) var maximumConcurrentCommands = 0

    init(binaryDirectory: URL) {
        self.binaryDirectory = binaryDirectory
    }

    func run(
        _ command: SubprocessCommand,
        onOutput: SubprocessOutputHandler?
    ) async throws -> SubprocessResult {

        concurrentCommands += 1
        maximumConcurrentCommands = max(maximumConcurrentCommands, concurrentCommands)
        defer { concurrentCommands -= 1 }
        try await Task.sleep(for: .milliseconds(5))

        if command.arguments.contains("dump-package") {
            return SubprocessResult(
                succeeded: true,
                standardOutput: """
                    {"products":[{"name":"Tool","targets":["Tool"],"type":{"executable":null}}],
                     "targets":[{"name":"Tool","type":"executable","dependencies":[],"resources":[]}]}
                    """,
                standardError: ""
            )
        }
        if command.arguments.contains("--show-bin-path") {
            return SubprocessResult(
                succeeded: true,
                standardOutput: binaryDirectory.path + "\n",
                standardError: ""
            )
        }

        return SubprocessResult(succeeded: true, standardOutput: "", standardError: "")
    }

}
