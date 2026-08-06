import Foundation

/// Errors reported by SwiftlyKit.
public enum SwiftlyKitError: Error, Equatable, Sendable {
    
    case unsupportedHost
    case developerToolsUnavailable
    
}

extension SwiftlyKitError: LocalizedError {
    
    public var errorDescription: String? {
        switch self {
            case .unsupportedHost: "SwiftlyKit requires Apple silicon macOS 13 or later."
            case .developerToolsUnavailable: "A usable macOS SDK is unavailable; install or select Xcode or Command Line Tools."
        }
    }
    
}
