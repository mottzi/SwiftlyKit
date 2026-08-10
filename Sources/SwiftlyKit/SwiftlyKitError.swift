import Foundation

/// Errors reported by SwiftlyKit.
public enum SwiftlyKitError: Error, Equatable, Sendable {
    case invalidPackageRoot(URL)
    case unsupportedHost
    case developerToolsUnavailable
    case commandLineToolsInstallationRequestFailed(String)
    case malformedToolsVersion
    case unsupportedToolsVersion(SwiftVersion)
    case incompatibleSwiftly
    case swiftlyInstallationFailed(String)
    case networkFailure(String)
    case integrityCheckFailed(String)
    case compatibleReleaseUnavailable
    case staticLinuxSDKUnavailable
    case staleAssessment
    case packageInspectionFailed(String)
    case dependencyResolutionRequired
    case dependencyResolutionFailed(String)
    case executableProductSelectionRequired([String])
    case executableProductNotFound(String)
    case unsupportedProductResources(String)
    case buildFailed(String)
    case stripFailed(String)
    case executableVerificationFailed(String)
    case outputAlreadyExists(URL)
    case outputPublicationFailed(URL)
}

extension SwiftlyKitError: LocalizedError {

    public var errorDescription: String? {
        switch self {
            case .invalidPackageRoot: "The package root must be a readable local directory containing Package.swift."
            case .unsupportedHost: "SwiftlyKit requires Apple silicon macOS 13 or later."
            case .developerToolsUnavailable: "A usable macOS SDK is unavailable; install or select Xcode or Command Line Tools."
            case .commandLineToolsInstallationRequestFailed(let detail):
                "The Command Line Tools installation could not be requested: \(detail)"
            case .malformedToolsVersion: "Package.swift does not contain a supported swift-tools-version declaration."
            case .unsupportedToolsVersion(let version): "No supported official Swift release is compatible with tools version \(version)."
            case .incompatibleSwiftly: "Swiftly 1.0 or later is required; an existing Swiftly installation is not replaced automatically."
            case .swiftlyInstallationFailed(let detail): "Swiftly could not be installed: \(detail)"
            case .networkFailure(let detail): "A required download failed: \(detail)"
            case .integrityCheckFailed(let detail): "A downloaded component could not be trusted: \(detail)"
            case .compatibleReleaseUnavailable: "No compatible official stable Swift release and Static Linux SDK are available."
            case .staticLinuxSDKUnavailable: "The exact selected Static Linux SDK is unavailable."
            case .staleAssessment: "Package.swift or .swift-version changed after the environment was assessed."
            case .packageInspectionFailed(let detail): "SwiftPM could not inspect the package: \(detail)"
            case .dependencyResolutionRequired: "Package dependencies must be resolved explicitly before building."
            case .dependencyResolutionFailed(let detail): "SwiftPM could not resolve package dependencies: \(detail)"
            case .executableProductSelectionRequired(let products) where products.isEmpty: "The package does not declare an executable product."
            case .executableProductSelectionRequired(let products): "The package declares multiple executable products; specify one of: \(products.joined(separator: ", "))."
            case .executableProductNotFound(let product): "SwiftPM did not produce the executable product “\(product)”."
            case .unsupportedProductResources(let product): "The executable product “\(product)” requires runtime resources."
            case .buildFailed(let detail): "SwiftPM could not build the executable: \(detail)"
            case .stripFailed(let detail): "The executable could not be stripped: \(detail)"
            case .executableVerificationFailed(let detail): "The produced executable failed verification: \(detail)"
            case .outputAlreadyExists(let url): "The output already exists at \(url.path)."
            case .outputPublicationFailed(let url): "The executable could not be published at \(url.path)."
        }
    }

}
