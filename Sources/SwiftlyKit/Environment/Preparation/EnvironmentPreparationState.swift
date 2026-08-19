import Foundation

/// One coherent observation used while preparing an assessed environment.
struct EnvironmentPreparationState: Sendable {

    let swiftly: SwiftlyInstallation?
    let inventory: InstalledEnvironmentInventory
    let sdkBundleURL: URL?

}

/// Owns host/package preflight and consistent installed-state observations.
protocol EnvironmentPreparationStateObserving: Sendable {

    func preflight(_ assessment: EnvironmentAssessment) async throws -> EnvironmentPreparationState

    func refresh(_ assessment: EnvironmentAssessment) async throws -> EnvironmentPreparationState

}

/// Live preparation-state adapter for the selected environment namespace.
struct LiveEnvironmentPreparationStateObserver: EnvironmentPreparationStateObserving {

    private let homeDirectory: URL
    private let inspector: InstalledEnvironmentInspector

    init(homeDirectory: URL, runner: any SubprocessRunning) {
        self.homeDirectory = homeDirectory
        self.inspector = InstalledEnvironmentInspector(runner: runner)
    }

    func preflight(_ assessment: EnvironmentAssessment) async throws -> EnvironmentPreparationState {
        try (await HostPreflight().assess()).requireReady()
        try assessment.packageInputs.validateCurrent()
        return try await refresh(assessment)
    }

    func refresh(_ assessment: EnvironmentAssessment) async throws -> EnvironmentPreparationState {
        let swiftly = try await SwiftlyInstallation.detect(
            storage: assessment.environmentStorage,
            homeDirectory: homeDirectory
        )
        let inventory: InstalledEnvironmentInventory
        if let swiftly {
            inventory = try await inspector.inspect(
                swiftly: swiftly,
                selectedToolchain: assessment.swiftVersion
            )
        } else {
            inventory = InstalledEnvironmentInventory(toolchains: [], sdks: [])
        }

        return EnvironmentPreparationState(
            swiftly: swiftly,
            inventory: inventory,
            sdkBundleURL: SDKBundleLocator.locate(
                identifier: assessment.staticLinuxSDK.identifier,
                in: assessment.environmentStorage,
                homeDirectory: homeDirectory
            )
        )
    }

}
