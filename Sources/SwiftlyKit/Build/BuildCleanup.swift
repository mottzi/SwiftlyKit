/// Cleanup performed after a runnable directory is published outside build storage.
public enum BuildCleanup: Sendable, Equatable {

    /// Retains all SwiftPM scratch storage for incremental builds.
    case retain

    /// Removes compiled products and intermediates while retaining reusable dependency state.
    case clean

    /// Removes the entire effective SwiftPM scratch directory, including dependency storage.
    case reset

}
