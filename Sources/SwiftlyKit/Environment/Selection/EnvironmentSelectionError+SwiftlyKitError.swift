extension EnvironmentSelectionPolicy.SelectionError {
    
    var swiftlyKitError: SwiftlyKitError {
        switch self {
            case .incompatibleToolsVersion(_, let required):
                .unsupportedToolsVersion(required)
            case .invalidSwiftVersionPreference,
                 .unavailableRelease,
                 .noCompatibleRelease:
                .compatibleReleaseUnavailable
            case .unsupportedArchitecture:
                .staticLinuxSDKUnavailable
        }
    }
    
}
