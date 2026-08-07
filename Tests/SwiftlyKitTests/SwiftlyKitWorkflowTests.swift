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
            let assessment = EnvironmentAssessment(
                packageRoot: packageRoot,
                toolsVersion: SwiftVersion(major: 6, minor: 0, patch: 0),
                swiftVersion: version,
                staticLinuxSDK: StaticLinuxSDK(identifier: "sdk", version: "1.0.0"),
                isSwiftlyAvailable: true,
                isToolchainAvailable: true,
                isStaticLinuxSDKAvailable: true,
                requiredComponents: [],
                target: .linux(.arm64),
                swiftVersionPreference: nil,
                swiftVersionFileURL: nil,
                swiftlyExecutableURL: packageRoot.appending(path: "swiftly"),
                sdkDownloadURL: URL(string: "https://download.swift.org/sdk.tar.gz")!,
                sdkChecksum: String(repeating: "a", count: 64),
                sdkBundleURL: packageRoot.appending(path: "sdk.artifactbundle"),
                manifestContents: originalManifest,
                swiftVersionFileContents: nil
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
                executableURL: packageRoot.appending(path: "swiftly"),
                version: "1.0.0"
            )
            let inventory = InstalledEnvironmentInventory(
                toolchains: [InstalledStableToolchain(version: version)],
                sdks: [InstalledStaticLinuxSDK(
                    toolchainVersion: version,
                    identifier: sdkIdentifier
                )]
            )
            let release = OfficialStableRelease(
                version: version,
                toolchainName: "6.2.1",
                staticLinuxSDK: OfficialStaticLinuxSDK(
                    version: "0.0.1",
                    identifier: sdkIdentifier,
                    downloadURL: URL(string: "https://download.swift.org/sdk.tar.gz")!,
                    checksum: String(repeating: "a", count: 64),
                    supportedArchitectures: [.arm64]
                )
            )
            let runner = WorkflowRunner(results: [SubprocessResult(
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
            
            #expect(!assessment.requiresPreparation)
            #expect(environment.swiftVersion == version)
            #expect(products.map(\.name) == ["Tool"])
        }
    }
    
}

private actor WorkflowRunner: SubprocessRunning {
    
    private var results: [SubprocessResult]
    
    init(results: [SubprocessResult]) {
        self.results = results
    }
    
    func run(
        _ command: SubprocessCommand,
        onOutput: SubprocessOutputHandler?
    ) async throws -> SubprocessResult {
        guard !results.isEmpty else { throw WorkflowTestError.unexpectedCommand(command) }
        return results.removeFirst()
    }
    
}

private enum WorkflowTestError: Error {
    case unexpectedCommand(SubprocessCommand)
}

private func withWorkflowTemporaryDirectory<T>(
    _ body: (URL) async throws -> T
) async throws -> T {
    
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SwiftlyKit-Workflow-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}
