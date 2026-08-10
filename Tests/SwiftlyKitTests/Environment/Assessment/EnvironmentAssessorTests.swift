import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Environment assessor")
struct EnvironmentAssessorTests {

    @Test("Missing Swiftly describes every required installation without inspecting installed state")
    func missingSwiftlyRequirements() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            let release = assessorRelease()
            let assessor = EnvironmentAssessor(
                checkHost: {},
                detectSwiftly: { nil },
                loadReleases: { [release] },
                inspectInventory: { _ in
                    Issue.record("Installed state must not be inspected without Swiftly.")
                    return InstalledEnvironmentInventory(toolchains: [], sdks: [])
                },
                locateSDK: { _ in nil }
            )

            let assessment = try await assessor.assess(
                packageRoot,
                for: .linux(.arm64),
                toolchain: .automatic
            )

            #expect(assessment.requiredComponents == [.swiftly, .toolchain, .staticLinuxSDK])
            #expect(assessment.swiftVersion == release.version)
            #expect(assessment.requiresInstallation)
        }
    }

    @Test("Host rejection short-circuits package and network work")
    func hostRejectionShortCircuits() async {

        let assessor = EnvironmentAssessor(
            checkHost: { throw SwiftlyKitError.unsupportedHost },
            detectSwiftly: { Issue.record("Swiftly detection must not run."); return nil },
            loadReleases: { Issue.record("Catalog loading must not run."); return [] },
            inspectInventory: { _ in
                Issue.record("Inventory inspection must not run.")
                return InstalledEnvironmentInventory(toolchains: [], sdks: [])
            },
            locateSDK: { _ in Issue.record("SDK lookup must not run."); return nil }
        )

        await #expect(throws: SwiftlyKitError.unsupportedHost) {
            try await assessor.assess(
                URL(filePath: "/does-not-need-to-exist"),
                for: .linux(.arm64),
                toolchain: .automatic
            )
        }
    }

    @Test("Catalog integrity and availability failures remain distinct public errors")
    func catalogErrorMapping() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )

            let invalidCatalog = EnvironmentAssessor(
                checkHost: {},
                detectSwiftly: { nil },
                loadReleases: { throw SwiftOrgReleaseCatalog.CatalogError.invalidPayload }
            )
            await #expect(throws: SwiftlyKitError.integrityCheckFailed(
                "Swift.org returned unsupported release metadata."
            )) {
                try await invalidCatalog.assess(
                    packageRoot,
                    for: .linux(.arm64),
                    toolchain: .automatic
                )
            }

            let unavailableCatalog = EnvironmentAssessor(
                checkHost: {},
                detectSwiftly: { nil },
                loadReleases: { throw SwiftOrgReleaseCatalog.CatalogError.networkFailure }
            )
            await #expect(throws: SwiftlyKitError.networkFailure(
                "The Swift.org release catalog is unavailable."
            )) {
                try await unavailableCatalog.assess(
                    packageRoot,
                    for: .linux(.arm64),
                    toolchain: .automatic
                )
            }
        }
    }

    @Test("Unreadable installed state makes an existing Swiftly installation incompatible")
    func inventoryFailureMapping() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            let swiftly = SwiftlyInstallation(executableURL: packageRoot.appending(path: "swiftly"))
            let assessor = EnvironmentAssessor(
                checkHost: {},
                detectSwiftly: { swiftly },
                loadReleases: { [assessorRelease()] },
                inspectInventory: { _ in throw InstalledEnvironmentError.invalidOutput }
            )

            await #expect(throws: SwiftlyKitError.incompatibleSwiftly) {
                try await assessor.assess(
                    packageRoot,
                    for: .linux(.arm64),
                    toolchain: .automatic
                )
            }
        }
    }

}

private func assessorRelease() -> OfficialStableRelease {

    let version = SwiftVersion(major: 6, minor: 3, patch: 3)
    return OfficialStableRelease(
        version: version,
        staticLinuxSDK: StaticLinuxSDK(
            identifier: "swift-6.3.3-RELEASE_static-linux-0.1.0",
            version: "0.1.0"
        ),
        staticLinuxSDKMetadata: StaticLinuxSDKMetadata(
            downloadURL: URL(string: "https://download.swift.org/sdk.tar.gz")!,
            checksum: String(repeating: "a", count: 64),
            supportedArchitectures: [.arm64]
        )
    )
}
