import Foundation

/// The location and lifecycle of a successfully built runnable output.
public enum BuildOutput: Sendable, Equatable {

    /// Returns the launch executable in managed SwiftPM build storage.
    /// Required runtime resource bundles remain beside the executable.
    case buildStorage

    /// Atomically publishes the complete runnable directory, then performs the requested cleanup.
    /// Replacement is opt-in. The parent must exist. Non-retaining cleanup requires publication outside build storage.
    case publish(to: URL, replacingExisting: Bool = false, cleanup: BuildCleanup = .retain)

}
