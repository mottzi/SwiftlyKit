import Foundation

enum BuildRuntimeError: Error, Equatable, Sendable {
    
    case invalidEnvironment
    case commandFailed(operation: String, diagnostic: String)
    case malformedPackageDescription
    case dependencyResolutionRequired
    case executableNotFound(String)
    case unsupportedProductResources(String)
    case invalidExecutable(String)
    case outputAlreadyExists(URL)
    case outputPublicationFailed(URL)
    
}
