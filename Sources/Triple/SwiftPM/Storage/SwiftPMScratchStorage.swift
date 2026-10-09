import Foundation

/// SwiftPM scratch storage used by a build, dependency resolution, or cleanup operation.
public enum SwiftPMScratchStorage: Sendable, Equatable {

    /// The package's `.build` directory.
    case packageDefault

    /// An explicit SwiftPM scratch directory.
    /// It must not equal or contain the package root, or overlap explicit shared storage.
    case directory(URL)

}
