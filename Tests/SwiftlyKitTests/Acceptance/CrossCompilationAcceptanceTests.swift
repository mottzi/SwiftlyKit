import Foundation
import SwiftlyKit
import Testing

@Suite("Cross-compilation acceptance")
struct CrossCompilationAcceptanceTests {

    @Test(
        "Cross-compilation package builds verified ARM64 and x86-64 executables",
        .enabled(
            if: ProcessInfo.processInfo.environment["SWIFTLYKIT_RUN_ACCEPTANCE"] == "1",
            "Run explicitly with SWIFTLYKIT_RUN_ACCEPTANCE=1."
        )
    )
    func packageBuildsBothArchitectures() async throws {

        let resourceRoot = try #require(Bundle.module.resourceURL)
        let packageRoot = resourceRoot.appending(
            path: "CrossCompilationPackage",
            directoryHint: .isDirectory
        )
        let kit = SwiftlyKit()

        try await withTemporaryDirectory(prefix: "SwiftlyKit-CrossCompilationAcceptance") { scratchRoot in
            for architecture in [LinuxArchitecture.arm64, .x86_64] {
                let assessment = try await kit.assess(
                    packageRoot,
                    for: .linux(architecture)
                )
                try #require(
                    !assessment.requiresInstallation,
                    "Acceptance does not authorize installation; prepare Swiftly, Swift \(assessment.swiftVersion), and \(assessment.staticLinuxSDK.identifier) first."
                )

                let environment = try await kit.prepare(assessment)
                let products = try await kit.executableProducts(using: environment)
                let product = try #require(
                    products.first { $0.name == "CrossCompilationFixture" }
                )
                let scratchDirectory = scratchRoot.appending(
                    path: String(describing: architecture),
                    directoryHint: .isDirectory
                )
                let executable = try await kit.build(
                    BuildRequest(
                        product,
                        configuration: .release,
                        scratchDirectory: scratchDirectory
                    ),
                    using: environment
                )

                #expect(FileManager.default.isExecutableFile(atPath: executable.path))
                #expect(executable.path.hasPrefix(scratchDirectory.path + "/"))
            }
        }
    }

    @Test(
        "A second identical build does not compile or link",
        .enabled(
            if: ProcessInfo.processInfo.environment["SWIFTLYKIT_RUN_ACCEPTANCE"] == "1",
            "Run explicitly with SWIFTLYKIT_RUN_ACCEPTANCE=1."
        )
    )
    func consecutiveIdenticalBuildIsIncremental() async throws {

        let resourceRoot = try #require(Bundle.module.resourceURL)
        let packageRoot = resourceRoot.appending(
            path: "CrossCompilationPackage",
            directoryHint: .isDirectory
        )
        let kit = SwiftlyKit()
        let assessment = try await kit.assess(packageRoot, for: .linux(.x86_64))
        try #require(
            !assessment.requiresInstallation,
            "Acceptance does not authorize installation; prepare Swiftly, Swift \(assessment.swiftVersion), and \(assessment.staticLinuxSDK.identifier) first."
        )
        let environment = try await kit.prepare(assessment)
        let products = try await kit.executableProducts(using: environment)
        let product = try #require(
            products.first { $0.name == "CrossCompilationFixture" }
        )

        try await withTemporaryDirectory(prefix: "SwiftlyKit-IncrementalAcceptance") { scratchDirectory in
            let request = BuildRequest(
                product,
                configuration: .release,
                scratchDirectory: scratchDirectory
            )
            let firstOutput = AcceptanceOutputRecorder()
            let firstExecutable = try await kit.build(
                request,
                using: environment,
                onEvent: { await firstOutput.record($0) }
            )
            let firstText = await firstOutput.text
            let firstIdentity = try executableIdentity(at: firstExecutable)

            let secondOutput = AcceptanceOutputRecorder()
            let secondExecutable = try await kit.build(
                request,
                using: environment,
                onEvent: { await secondOutput.record($0) }
            )
            let secondText = await secondOutput.text
            let secondIdentity = try executableIdentity(at: secondExecutable)

            #expect(firstText.contains("Compiling CrossCompilationFixture"))
            #expect(firstText.contains("Linking CrossCompilationFixture"))
            #expect(!secondText.contains("Compiling CrossCompilationFixture"))
            #expect(!secondText.contains("Linking CrossCompilationFixture"))
            #expect(secondExecutable == firstExecutable)
            #expect(secondIdentity == firstIdentity)
        }
    }

}

private func executableIdentity(at url: URL) throws -> ExecutableIdentity {

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return ExecutableIdentity(
        inode: try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value,
        modificationDate: try #require(attributes[.modificationDate] as? Date)
    )
}

private actor AcceptanceOutputRecorder {

    private(set) var text = ""

    func record(_ event: SwiftlyKitEvent) {
        guard case let .output(output) = event else { return }
        text += output.text
    }

}

private struct ExecutableIdentity: Equatable {

    let inode: UInt64
    let modificationDate: Date

}
