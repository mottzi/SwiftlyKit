import Foundation

extension PackageRequirements.LoadingError {
    
    var swiftlyKitError: SwiftlyKitError {
        switch self {
            case .invalidPackageRoot(let url): .invalidPackageRoot(url)
            case .unreadableManifest(let url): .invalidPackageRoot(url.deletingLastPathComponent())
            case .malformedToolsVersion: .malformedToolsVersion
            case .toolsVersionMustBeFirstLine(let version): .unsupportedToolsVersion(version)
            case .unreadableSwiftVersionFile: .staleAssessment
        }
    }
    
}
