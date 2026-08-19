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
                    """
                    Acceptance does not authorize installation; prepare Swiftly, Swift \(assessment.swiftVersion), \
                    and \(assessment.staticLinuxSDK.identifier) first.
                    """
                )

                let environment = try await kit.prepare(assessment)
                let products = try await kit.executableProducts(using: environment)
                let product = try products.select("CrossCompilationFixture")
                let scratchDirectory = scratchRoot.appending(
                    path: String(describing: architecture),
                    directoryHint: .isDirectory
                )
                let publication = scratchRoot.appending(
                    path: "Published-\(String(describing: architecture))",
                    directoryHint: .isDirectory
                )
                let result = try await kit.build(
                    BuildRequest(
                        product,
                        configuration: .release,
                        scratchStorage: .directory(scratchDirectory),
                        output: .publish(to: publication)
                    ),
                    using: environment
                )

                #expect(FileManager.default.isExecutableFile(atPath: result.executable.path(percentEncoded: false)))
                #expect(result.executable == publication.appending(path: "CrossCompilationFixture"))
                #expect(result.resourceBundles == [
                    publication.appending(
                        path: "ResourceDependency_ResourceDependency.resources",
                        directoryHint: .isDirectory
                    )
                ])
                #expect(result.directory == publication)
                #expect(Set(try FileManager.default.contentsOfDirectory(atPath: publication.path())) == [
                    "CrossCompilationFixture",
                    "ResourceDependency_ResourceDependency.resources"
                ])
                let message = publication.appending(
                    path: "ResourceDependency_ResourceDependency.resources/message.txt"
                )
                #expect(try String(contentsOf: message, encoding: .utf8).contains("SwiftlyKit cross-compilation fixture"))
            }
        }
    }

    @Test(
        "A second identical build preserves artifact identity",
        .enabled(
            if: ProcessInfo.processInfo.environment["SWIFTLYKIT_RUN_ACCEPTANCE"] == "1",
            "Run explicitly with SWIFTLYKIT_RUN_ACCEPTANCE=1."
        )
    )
    func consecutiveIdenticalBuildPreservesArtifactIdentity() async throws {

        let resourceRoot = try #require(Bundle.module.resourceURL)
        let packageRoot = resourceRoot.appending(
            path: "CrossCompilationPackage",
            directoryHint: .isDirectory
        )
        let kit = SwiftlyKit()
        let assessment = try await kit.assess(packageRoot, for: .linux(.x86_64))
        try #require(
            !assessment.requiresInstallation,
            """
            Acceptance does not authorize installation; prepare Swiftly, Swift \(assessment.swiftVersion), \
            and \(assessment.staticLinuxSDK.identifier) first.
            """
        )
        let environment = try await kit.prepare(assessment)
        let products = try await kit.executableProducts(using: environment)
        let product = try products.select("CrossCompilationFixture")

        try await withTemporaryDirectory(prefix: "SwiftlyKit-IncrementalAcceptance") { scratchDirectory in
            let request = BuildRequest(
                product,
                configuration: .release,
                scratchStorage: .directory(scratchDirectory)
            )
            let firstResult = try await kit.build(
                request,
                using: environment
            )
            let firstIdentity = try executableIdentity(at: firstResult.executable)

            let secondResult = try await kit.build(
                request,
                using: environment
            )
            let secondIdentity = try executableIdentity(at: secondResult.executable)

            #expect(secondResult.executable == firstResult.executable)
            #expect(secondResult.resourceBundles == firstResult.resourceBundles)
            #expect(secondIdentity == firstIdentity)
        }
    }

}

private func executableIdentity(at url: URL) throws -> ExecutableIdentity {

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    return ExecutableIdentity(
        inode: try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value,
        modificationDate: try #require(attributes[.modificationDate] as? Date)
    )
}

private struct ExecutableIdentity: Equatable {

    let inode: UInt64
    let modificationDate: Date

}
