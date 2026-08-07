import Foundation

enum SwiftPMError: Error, Equatable, Sendable {
    
    case commandFailed(operation: SwiftPMOperation, diagnostic: String)
    case malformedPackageDescription
    case dependencyResolutionRequired
    case executableNotFound(String)
    case unsupportedProductResources(String)
    case invalidExecutable(String)
    case outputAlreadyExists(URL)
    case outputPublicationFailed(URL)
    
}

enum SwiftPMOperation: Equatable, Sendable {
    
    case build
    case locatingBuildOutput
    case packageDescription
    case dependencyResolution
    case stripping
    
}

extension SwiftPMError {
    
    var swiftlyKitError: SwiftlyKitError {
        switch self {
            case .commandFailed(let operation, let diagnostic):
                switch operation {
                    case .build, .locatingBuildOutput: .buildFailed(diagnostic)
                    case .packageDescription: .packageInspectionFailed(diagnostic)
                    case .dependencyResolution: .dependencyResolutionFailed(diagnostic)
                    case .stripping: .stripFailed(diagnostic)
                }
            case .malformedPackageDescription:
                .packageInspectionFailed("SwiftPM returned malformed package metadata.")
            case .dependencyResolutionRequired:
                .dependencyResolutionRequired
            case .executableNotFound(let product):
                .executableProductNotFound(product)
            case .unsupportedProductResources(let product):
                .unsupportedProductResources(product)
            case .invalidExecutable(let detail):
                .executableVerificationFailed(detail)
            case .outputAlreadyExists(let url):
                .outputAlreadyExists(url)
            case .outputPublicationFailed(let url):
                .outputPublicationFailed(url)
        }
    }
    
}
