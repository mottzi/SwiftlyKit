import Foundation
import SwiftlyKit
import Testing

@Suite("Cross-compilation acceptance")
struct CrossCompilationAcceptanceTests {

    @Test(
        "Triple fixture builds verified ARM64 and x86-64 executables",
        .enabled(
            if: ProcessInfo.processInfo.environment["SWIFTLYKIT_RUN_ACCEPTANCE"] == "1",
            "Run explicitly with SWIFTLYKIT_RUN_ACCEPTANCE=1."
        )
    )
    func tripleFixtureBuildsBothArchitectures() async throws {

        let resourceRoot = try #require(Bundle.module.resourceURL)
        let packageRoot = resourceRoot.appending(
            path: "TripleCrossCompilation",
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

}
