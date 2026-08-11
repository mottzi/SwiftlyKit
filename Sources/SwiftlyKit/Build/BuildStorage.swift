import Foundation

/// The SwiftPM scratch storage used by a build.
public enum BuildStorage: Sendable, Equatable {
    /// The package's `.build` directory.
    case packageDefault

    /// An explicit SwiftPM scratch directory.
    /// It must not equal or contain the package root.
    case directory(URL)
}
