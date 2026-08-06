import Foundation

/// Errors reported by SwiftlyKit.
public enum SwiftlyKitError: Error, Equatable, Sendable {
    
    case unsupportedHost
    case developerToolsUnavailable
    case incompatibleSwiftly
    
}

extension SwiftlyKitError: LocalizedError {
    
    public var errorDescription: String? {
        switch self {
            case .unsupportedHost: "SwiftlyKit requires Apple silicon macOS 13 or later."
            case .developerToolsUnavailable: "A usable macOS SDK is unavailable; install or select Xcode or Command Line Tools."
            case .incompatibleSwiftly: "Swiftly 1.0 or later is required; an existing Swiftly installation is not replaced automatically."
        }
    }
    
}
