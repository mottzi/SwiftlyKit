extension EnvironmentPreparationError {
    
    var swiftlyKitError: SwiftlyKitError {
        switch self {
            case .invalidDownloadURL:
                .integrityCheckFailed("An official download URL was invalid.")
            case .invalidHTTPResponse(let status):
                .networkFailure("Swift.org returned HTTP \(status).")
            case .downloadFailed:
                .networkFailure("The official Swiftly package could not be downloaded.")
            case .packageSignatureRejected:
                .integrityCheckFailed("The Swiftly installer signature or Apple trust check failed.")
            case .installationFailed(let detail):
                .swiftlyInstallationFailed(detail)
            case .commandCouldNotRun(let url):
                .swiftlyInstallationFailed("Could not run \(url.lastPathComponent).")
            case .swiftlyUnavailableAfterInstallation:
                .swiftlyInstallationFailed("Swiftly was unavailable after installation.")
            case .unauthorizedMutationRequired:
                .staleAssessment
        }
    }
    
}
