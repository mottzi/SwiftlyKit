import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Environment assessor")
struct EnvironmentAssessorTests {

    @Test("Assessment captures the selected environment storage namespace")
    func assessmentCapturesEnvironmentStorage() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            let storage = EnvironmentStorage.directory(
                packageRoot.deletingLastPathComponent().appending(path: "swiftly")
            )
            let release = assessorRelease()
            let assessor = testEnvironmentAssessor(
                environmentStorage: storage,
                releaseCatalog: TestAssessmentReleaseCatalog.current([release])
            )

            let assessment = try await assessor.assess(
                packageRoot,
                for: .linux(.arm64),
                toolchain: .automatic
            )

            #expect(
                try assessment.environmentStorage.resolved().homeDirectory
                    == storage.resolved().homeDirectory
            )

            let choices = try await assessor.compatibleEnvironments(
                packageRoot,
                for: .linux(.arm64)
            )
            let choice = try #require(choices.first)
            #expect(
                try choice.environmentStorage.resolved().homeDirectory
                    == storage.resolved().homeDirectory
            )
        }
    }

    @Test("Assessment rejects an environment root that overlaps the package")
    func assessmentRejectsPackageOverlap() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            let assessor = testEnvironmentAssessor(
                environmentStorage: .directory(packageRoot),
                releaseCatalog: TestAssessmentReleaseCatalog.current([])
            )

            await #expect(throws: SwiftlyKitError.unsafeEnvironmentStorage(packageRoot)) {
                try await assessor.assess(
                    packageRoot,
                    for: .linux(.arm64),
                    toolchain: .automatic
                )
            }
        }
    }

    @Test("Missing Swiftly describes every required installation without inspecting installed state")
    func missingSwiftlyRequirements() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            let release = assessorRelease()
            let assessor = testEnvironmentAssessor(
                releaseCatalog: TestAssessmentReleaseCatalog.current([release])
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
            environmentStorage: .standard,
            localEnvironment: TestLocalEnvironmentLoader { _, _ in
                throw SwiftlyKitError.unsupportedHost
            },
            releaseCatalog: TestAssessmentReleaseCatalog { _ in
                Issue.record("Catalog loading must not run.")
                return AssessmentCatalogSnapshot(releases: [], provenance: .current)
            }
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

            let invalidCatalog = testEnvironmentAssessor(
                releaseCatalog: TestAssessmentReleaseCatalog.failure(
                    .integrityCheckFailed("Swift.org returned unsupported release metadata.")
                )
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

            let unavailableCatalog = testEnvironmentAssessor(
                releaseCatalog: TestAssessmentReleaseCatalog.failure(
                    .networkFailure("The Swift.org release catalog is unavailable.")
                )
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

    @Test("A network failure reuses one exact fully installed cached pair")
    func networkFailureReusesInstalledPair() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )

            let release = assessorRelease()
            let inventory = InstalledEnvironmentInventory(
                toolchains: [release.version],
                sdks: [InstalledStaticLinuxSDK(
                    toolchainVersion: release.version,
                    identifier: release.staticLinuxSDK.identifier
                )]
            )
            let assessor = testEnvironmentAssessor(
                inventory: inventory,
                isSwiftlyAvailable: true,
                sdkBundleIdentifiers: [release.staticLinuxSDK.identifier],
                releaseCatalog: TestAssessmentReleaseCatalog.cached([release])
            )

            let assessment = try await assessor.assess(
                packageRoot,
                for: .linux(.arm64),
                toolchain: .exact(release.version)
            )

            #expect(assessment.swiftVersion == release.version)
            #expect(assessment.requiredComponents.isEmpty)
        }
    }

    @Test("Automatic cached selection honors the nearest Swift version preference")
    func automaticFallbackHonorsPreference() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            try Data("6.2.4\n".utf8).write(
                to: packageRoot.appending(path: ".swift-version")
            )

            let preferred = assessorRelease("6.2.4")
            let newer = assessorRelease("6.3.3")
            let inventory = InstalledEnvironmentInventory(
                toolchains: [preferred.version, newer.version],
                sdks: [preferred, newer].map {
                    InstalledStaticLinuxSDK(
                        toolchainVersion: $0.version,
                        identifier: $0.staticLinuxSDK.identifier
                    )
                }
            )
            let assessor = testEnvironmentAssessor(
                inventory: inventory,
                isSwiftlyAvailable: true,
                sdkBundleIdentifiers: [
                    preferred.staticLinuxSDK.identifier,
                    newer.staticLinuxSDK.identifier
                ],
                releaseCatalog: TestAssessmentReleaseCatalog.cached([preferred, newer])
            )

            let assessment = try await assessor.assess(
                packageRoot,
                for: .linux(.arm64),
                toolchain: .automatic
            )

            #expect(assessment.swiftVersion == preferred.version)
            #expect(assessment.requiredComponents.isEmpty)
        }
    }

    @Test("Cached metadata cannot authorize a missing SDK or a different exact release")
    func cachedMetadataCannotAuthorizeMutation() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )

            let installed = assessorRelease("6.2.4")
            let requested = assessorRelease("6.3.3")
            let inventory = InstalledEnvironmentInventory(
                toolchains: [installed.version, requested.version],
                sdks: [InstalledStaticLinuxSDK(
                    toolchainVersion: installed.version,
                    identifier: installed.staticLinuxSDK.identifier
                )]
            )
            let assessor = testEnvironmentAssessor(
                inventory: inventory,
                isSwiftlyAvailable: true,
                sdkBundleIdentifiers: [installed.staticLinuxSDK.identifier],
                releaseCatalog: TestAssessmentReleaseCatalog.cached([installed, requested])
            )

            await #expect(throws: SwiftlyKitError.networkFailure(
                "The Swift.org release catalog is unavailable."
            )) {
                try await assessor.assess(
                    packageRoot,
                    for: .linux(.arm64),
                    toolchain: .exact(requested.version)
                )
            }
        }
    }

    @Test("Discovery does not present a persistent fallback as a complete catalog")
    func discoveryRequiresLiveCatalog() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )

            let assessor = testEnvironmentAssessor(
                releaseCatalog: TestAssessmentReleaseCatalog { requirement in
                    guard case .currentOnly = requirement else {
                        Issue.record("Discovery must require current metadata.")
                        return AssessmentCatalogSnapshot(releases: [], provenance: .cache)
                    }
                    throw SwiftlyKitError.networkFailure(
                        "The Swift.org release catalog is unavailable."
                    )
                }
            )

            await #expect(throws: SwiftlyKitError.networkFailure(
                "The Swift.org release catalog is unavailable."
            )) {
                try await assessor.compatibleEnvironments(packageRoot, for: .linux(.arm64))
            }
        }
    }

    @Test("Unreadable installed state makes an existing Swiftly installation incompatible")
    func inventoryFailureMapping() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            let assessor = EnvironmentAssessor(
                environmentStorage: .standard,
                localEnvironment: TestLocalEnvironmentLoader { _, _ in
                    throw SwiftlyKitError.incompatibleSwiftly
                },
                releaseCatalog: TestAssessmentReleaseCatalog.current([assessorRelease()])
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

    @Test("Discovery returns unique compatible assessments from one installed-state observation")
    func compatibleEnvironmentDiscovery() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 6.2\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            let older = assessorRelease("6.2.4")
            let newer = assessorRelease("6.3.3")
            let unsupported = assessorRelease("6.4.1", architectures: [.x86_64])
            let incompatible = assessorRelease("6.1.2")
            let inventory = InstalledEnvironmentInventory(
                toolchains: [older.version],
                sdks: [InstalledStaticLinuxSDK(
                    toolchainVersion: older.version,
                    identifier: older.staticLinuxSDK.identifier
                )]
            )
            let inspections = AssessorCounter()
            let localEnvironment = TestLocalEnvironmentLoader(
                makeSnapshot: { packageRoot, environmentStorage in
                    await inspections.increment()
                    return try await TestLocalEnvironmentLoader(
                        inventory: inventory,
                        isSwiftlyAvailable: true,
                        sdkBundleIdentifiers: [older.staticLinuxSDK.identifier]
                    ).snapshot(packageRoot, environmentStorage)
                }
            )
            let assessor = EnvironmentAssessor(
                environmentStorage: .standard,
                localEnvironment: localEnvironment,
                releaseCatalog: TestAssessmentReleaseCatalog.current([
                    older,
                    newer,
                    newer,
                    unsupported,
                    incompatible
                ])
            )

            let choices = try await assessor.compatibleEnvironments(packageRoot, for: .linux(.arm64))
            let automatic = try choices.select(.automatic)
            let exact = try choices.select(.exact(newer.version))

            #expect(choices.map(\.swiftVersion) == [newer.version, older.version])
            #expect(choices[0].requiredComponents == [.toolchain, .staticLinuxSDK])
            #expect(choices[1].requiredComponents.isEmpty)
            #expect(automatic.swiftVersion == older.version)
            #expect(exact.swiftVersion == newer.version)
            #expect(await inspections.value == 1)
        }
    }

    @Test("An invalid automatic preference does not hide compatible exact choices")
    func invalidAutomaticPreferencePreservesChoices() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 6.2\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            try Data("main-snapshot\n".utf8).write(
                to: packageRoot.appending(path: ".swift-version")
            )
            let release = assessorRelease("6.3.3")
            let assessor = testEnvironmentAssessor(
                releaseCatalog: TestAssessmentReleaseCatalog.current([release])
            )

            let choices = try await assessor.compatibleEnvironments(packageRoot, for: .linux(.arm64))

            #expect(choices.map(\.swiftVersion) == [release.version])
            #expect(throws: SwiftlyKitError.compatibleReleaseUnavailable) {
                try choices.select(.automatic)
            }
            #expect(try choices.select(.exact(release.version)).swiftVersion == release.version)
        }
    }

    @Test("Discovery returns an empty collection if no release is compatible")
    func emptyCompatibleEnvironmentDiscovery() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 7.0\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            let assessor = testEnvironmentAssessor(
                releaseCatalog: TestAssessmentReleaseCatalog.current([
                    assessorRelease("6.3.3")
                ])
            )

            let choices = try await assessor.compatibleEnvironments(packageRoot, for: .linux(.arm64))

            #expect(choices.isEmpty)
            #expect(throws: SwiftlyKitError.compatibleReleaseUnavailable) {
                try choices.select(.automatic)
            }
        }
    }

    @Test("Choice selection preserves exact-selection failures")
    func choiceSelectionErrors() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Assessor") { packageRoot in
            try Data("// swift-tools-version: 6.3\n".utf8).write(
                to: packageRoot.appending(path: "Package.swift")
            )
            let old = assessorRelease("6.2.4")
            let wrongArchitecture = assessorRelease("6.4.1", architectures: [.x86_64])
            let compatible = assessorRelease("6.5.0")
            let unavailable = SwiftVersion(major: 7, minor: 0, patch: 0)
            let assessor = testEnvironmentAssessor(
                releaseCatalog: TestAssessmentReleaseCatalog.current([
                    old,
                    wrongArchitecture,
                    compatible
                ])
            )

            let choices = try await assessor.compatibleEnvironments(packageRoot, for: .linux(.arm64))

            #expect(throws: SwiftlyKitError.unsupportedToolsVersion(
                SwiftVersion(major: 6, minor: 3, patch: 0)
            )) {
                try choices.select(.exact(old.version))
            }
            #expect(throws: SwiftlyKitError.staticLinuxSDKUnavailable) {
                try choices.select(.exact(wrongArchitecture.version))
            }
            #expect(throws: SwiftlyKitError.compatibleReleaseUnavailable) {
                try choices.select(.exact(unavailable))
            }
        }
    }

}

private func assessorRelease(
    _ value: String = "6.3.3",
    architectures: Set<LinuxArchitecture> = [.arm64]
) -> OfficialStableRelease {

    let version = SwiftVersion(value)!
    return OfficialStableRelease(
        version: version,
        staticLinuxSDK: StaticLinuxSDK(
            identifier: "swift-\(value)-RELEASE_static-linux-0.1.0",
            version: "0.1.0"
        ),
        staticLinuxSDKMetadata: StaticLinuxSDKMetadata(
            downloadURL: URL(string: "https://download.swift.org/sdk.tar.gz")!,
            checksum: String(repeating: "a", count: 64),
            supportedArchitectures: architectures
        )!
    )
}

private actor AssessorCounter {

    private(set) var value = 0

    func increment() { value += 1 }

}
