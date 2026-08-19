import Foundation
@testable import SwiftlyKit

struct TestLocalEnvironmentLoader {

    private let makeSnapshot: @Sendable (
        URL,
        EnvironmentStorage
    ) async throws -> LocalEnvironmentSnapshot

    init(
        inventory: InstalledEnvironmentInventory = InstalledEnvironmentInventory(
            toolchains: [],
            sdks: []
        ),
        isSwiftlyAvailable: Bool = false,
        sdkBundleIdentifiers: Set<String> = []
    ) {
        self.init { packageRoot, environmentStorage in
            let packageInputs = try PackageInputSnapshot.capture(at: packageRoot)
            let validatedStorage = try environmentStorage.validated(
                against: packageInputs.packageRoot
            )
            return LocalEnvironmentSnapshot(
                packageInputs: packageInputs,
                environmentStorage: validatedStorage,
                inventory: inventory,
                isSwiftlyAvailable: isSwiftlyAvailable,
                sdkBundleExists: sdkBundleIdentifiers.contains
            )
        }
    }

    init(
        makeSnapshot: @escaping @Sendable (
            URL,
            EnvironmentStorage
        ) async throws -> LocalEnvironmentSnapshot
    ) {
        self.makeSnapshot = makeSnapshot
    }

    func snapshot(
        _ packageRoot: URL,
        _ environmentStorage: EnvironmentStorage
    ) async throws -> LocalEnvironmentSnapshot {
        try await makeSnapshot(packageRoot, environmentStorage)
    }

}

struct TestAssessmentReleaseCatalog {

    private let makeSnapshot: @Sendable (
        AssessmentCatalogRequirement
    ) async throws -> AssessmentCatalogSnapshot

    init(
        makeSnapshot: @escaping @Sendable (
            AssessmentCatalogRequirement
        ) async throws -> AssessmentCatalogSnapshot
    ) {
        self.makeSnapshot = makeSnapshot
    }

    func snapshot(
        _ requirement: AssessmentCatalogRequirement
    ) async throws -> AssessmentCatalogSnapshot {
        try await makeSnapshot(requirement)
    }

    static func current(_ releases: [OfficialStableRelease]) -> Self {
        Self { _ in
            AssessmentCatalogSnapshot(releases: releases, provenance: .current)
        }
    }

    static func cached(_ releases: [OfficialStableRelease]) -> Self {
        Self { requirement in
            guard case .currentOrCached = requirement else {
                throw SwiftlyKitError.networkFailure(
                    "The Swift.org release catalog is unavailable."
                )
            }
            return AssessmentCatalogSnapshot(releases: releases, provenance: .cache)
        }
    }

    static func failure(_ error: SwiftlyKitError) -> Self {
        Self { _ in throw error }
    }

}

func testEnvironmentAssessor(
    environmentStorage: EnvironmentStorage = .standard,
    inventory: InstalledEnvironmentInventory = InstalledEnvironmentInventory(
        toolchains: [],
        sdks: []
    ),
    isSwiftlyAvailable: Bool = false,
    sdkBundleIdentifiers: Set<String> = [],
    releaseCatalog: TestAssessmentReleaseCatalog
) -> EnvironmentAssessor {

    EnvironmentAssessor(
        environmentStorage: environmentStorage,
        loadLocalEnvironment: TestLocalEnvironmentLoader(
            inventory: inventory,
            isSwiftlyAvailable: isSwiftlyAvailable,
            sdkBundleIdentifiers: sdkBundleIdentifiers
        ).snapshot,
        loadReleaseCatalog: releaseCatalog.snapshot
    )
}

extension EnvironmentAssessor {

    init(
        environmentStorage: EnvironmentStorage,
        localEnvironment: TestLocalEnvironmentLoader,
        releaseCatalog: TestAssessmentReleaseCatalog
    ) {
        self.init(
            environmentStorage: environmentStorage,
            loadLocalEnvironment: localEnvironment.snapshot,
            loadReleaseCatalog: releaseCatalog.snapshot
        )
    }

}
