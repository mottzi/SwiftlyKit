/// Text progress for a current operation and, during preparation, an optional component.
public struct OperationProgress: Sendable {

    /// The current workflow activity.
    public let operation: Operation

    /// The component being prepared, or `nil` if the activity is not environment preparation.
    public let component: PreparationComponent?

    /// A human-readable description of the current activity.
    public let detail: String

    init(
        operation: Operation,
        component: PreparationComponent? = nil,
        detail: String
    ) {
        self.operation = operation
        self.component = component
        self.detail = detail
    }

}

extension OperationProgress {
    
    /// A mutating workflow activity that can emit progress.
    public enum Operation: Sendable {

        /// Installation of a required environment component.
        case preparingEnvironment

        /// Removal of exact Swiftly-managed environment resources.
        case removingEnvironment

        /// Explicit SwiftPM package dependency resolution.
        case resolvingDependencies

        /// SwiftPM compilation and linking for the selected product.
        case building

        /// Symbol removal from the verified executable.
        case stripping

        /// Atomic publication of the verified runnable directory to the requested output URL.
        case publishing

        /// Removal of compiled products and intermediate build artifacts.
        case cleaningBuildArtifacts

        /// Removal of the complete effective SwiftPM scratch directory.
        case resettingBuildStorage

    }
    
}
