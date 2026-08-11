import Foundation

enum SwiftPMError: Error, Equatable {
    case commandFailed(operation: Operation, diagnostic: String)
    case sdkSearchPathPreparationFailed(String)
    case malformedPackageDescription
    case dependencyResolutionRequired
    case executableNotFound(String)
    case unsupportedProductResources(String)
    case invalidExecutable(String)
    case unsafeBuildStorage(URL)
    case outputInsideBuildStorage(URL)
    case outputAlreadyExists(URL)
    case outputCopyFailed(URL)
    case postBuildCleanupFailed(output: URL, diagnostic: String)
}

extension SwiftPMError {

    var swiftlyKitError: SwiftlyKitError {
        switch self {
            case .sdkSearchPathPreparationFailed(let detail): .buildFailed(detail)
            case .malformedPackageDescription: .packageInspectionFailed("SwiftPM returned malformed package metadata.")
            case .dependencyResolutionRequired: .dependencyResolutionRequired
            case .executableNotFound(let product): .executableProductNotFound(product)
            case .unsupportedProductResources(let product): .unsupportedProductResources(product)
            case .invalidExecutable(let detail): .executableVerificationFailed(detail)
            case .unsafeBuildStorage(let url): .unsafeBuildStorage(url)
            case .outputInsideBuildStorage(let url): .outputInsideBuildStorage(url)
            case .outputAlreadyExists(let url): .outputAlreadyExists(url)
            case .outputCopyFailed(let url): .outputCopyFailed(url)
            case .postBuildCleanupFailed(let output, let diagnostic):
                .postBuildCleanupFailed(output: output, detail: diagnostic)
            case .commandFailed(let operation, let diagnostic):
                switch operation {
                    case .building: .buildFailed(diagnostic)
                    case .inspectingPackage: .packageInspectionFailed(diagnostic)
                    case .resolvingDependencies: .dependencyResolutionFailed(diagnostic)
                    case .stripping: .stripFailed(diagnostic)
                    case .cleaningBuildArtifacts: .buildArtifactCleanupFailed(diagnostic)
                    case .resettingBuildStorage: .buildStorageResetFailed(diagnostic)
                }
        }
    }

    var cleanupDiagnostic: String {
        switch self {
            case .commandFailed(_, let diagnostic): diagnostic
            default: "An unexpected cleanup error occurred."
        }
    }

}

extension SwiftPMError {

    enum Operation {
        case building
        case inspectingPackage
        case resolvingDependencies
        case stripping
        case cleaningBuildArtifacts
        case resettingBuildStorage
    }

}
