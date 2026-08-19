import Foundation
@testable import SwiftlyKit

/// Test-only semantic adapter used to drive preparation scenarios without exposing
/// operation closures from the production EnvironmentPreparer initializer.
private struct TestEnvironmentPreparationState: EnvironmentPreparationStateObserving {

    let assessHost: @Sendable () async throws -> HostReadiness
    let detectSwiftly: @Sendable (EnvironmentStorage) async throws -> SwiftlyInstallation?
    let inspect: @Sendable (SwiftlyInstallation, SwiftVersion) async throws -> InstalledEnvironmentInventory
    let locateSDK: @Sendable (String, EnvironmentStorage) -> URL?
    let revalidate: @Sendable (EnvironmentAssessment) async throws -> Void

    func preflight(_ assessment: EnvironmentAssessment) async throws -> EnvironmentPreparationState {
        try (await assessHost()).requireReady()
        try await revalidate(assessment)
        return try await refresh(assessment)
    }

    func refresh(_ assessment: EnvironmentAssessment) async throws -> EnvironmentPreparationState {
        let swiftly = try await detectSwiftly(assessment.environmentStorage)
        let inventory: InstalledEnvironmentInventory
        if let swiftly {
            inventory = try await inspect(swiftly, assessment.swiftVersion)
        } else {
            inventory = InstalledEnvironmentInventory(toolchains: [], sdks: [])
        }
        return EnvironmentPreparationState(
            swiftly: swiftly,
            inventory: inventory,
            sdkBundleURL: locateSDK(
                assessment.staticLinuxSDK.identifier,
                assessment.environmentStorage
            )
        )
    }

}

private struct TestPackageDownloader: PackageDownloading {

    let operation: @Sendable (URL, URL) async throws -> Void

    func download(from source: URL, to destination: URL) async throws {
        try await operation(source, destination)
    }

}

extension EnvironmentPreparer {

    /// Compatibility construction for focused tests; it composes semantic test adapters.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        runner: any SubprocessRunning = LiveSubprocessRunner(),
        assessHost: @escaping @Sendable () async throws -> HostReadiness = {
            try await HostPreflight().assess()
        },
        downloadPackage: @escaping @Sendable (URL, URL) async throws -> Void = {
            try await HTTPPackageDownloader().download(from: $0, to: $1)
        },
        detectSwiftly: (@Sendable () async throws -> SwiftlyInstallation?)? = nil,
        inspect: @escaping @Sendable (SwiftlyInstallation, SwiftVersion) async throws
            -> InstalledEnvironmentInventory = { swiftly, toolchain in
            try await InstalledEnvironmentInspector().inspect(
                swiftly: swiftly,
                selectedToolchain: toolchain
            )
        },
        locateSDK: (@Sendable (String) -> URL?)? = nil,
        revalidate: @escaping @Sendable (EnvironmentAssessment) async throws -> Void = {
            try $0.packageInputs.validateCurrent()
        }
    ) {
        let detector: @Sendable (EnvironmentStorage) async throws -> SwiftlyInstallation?
        if let detectSwiftly {
            detector = { _ in try await detectSwiftly() }
        } else {
            detector = { storage in
                try await SwiftlyInstallation.detect(
                    storage: storage,
                    homeDirectory: homeDirectory
                )
            }
        }
        let sdkLocator: @Sendable (String, EnvironmentStorage) -> URL? = { identifier, storage in
            if let locateSDK { return locateSDK(identifier) }
            return SDKBundleLocator.locate(
                identifier: identifier,
                in: storage,
                homeDirectory: homeDirectory
            )
        }
        self.init(
            homeDirectory: homeDirectory,
            temporaryDirectory: temporaryDirectory,
            runner: runner,
            preparationState: TestEnvironmentPreparationState(
                assessHost: assessHost,
                detectSwiftly: detector,
                inspect: inspect,
                locateSDK: sdkLocator,
                revalidate: revalidate
            ),
            packageDownloader: TestPackageDownloader(operation: downloadPackage)
        )
    }

}
