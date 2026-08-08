import Foundation

enum InstalledEnvironmentError: Error, Equatable, Sendable {
    case commandCouldNotRun(URL)
    case commandFailed(String)
    case invalidOutput
}

extension InstalledEnvironmentError {
    
    var swiftlyKitError: SwiftlyKitError {
        switch self {
            case .commandCouldNotRun(let url): .swiftlyInstallationFailed("Could not run \(url.lastPathComponent).")
            case .commandFailed(let detail): .swiftlyInstallationFailed(detail)
            case .invalidOutput: .incompatibleSwiftly
        }
    }
    
}
