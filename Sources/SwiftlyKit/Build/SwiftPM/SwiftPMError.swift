import Foundation

enum SwiftPMError: Error, Equatable, Sendable {
    
    case invalidEnvironment
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
