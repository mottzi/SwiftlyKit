/// Progress information for one current workflow activity.
public struct OperationProgress: Sendable {

    /// The current workflow activity and its preparation context.
    public let operation: Operation

    /// Human-readable diagnostic text for the current activity.
    /// Consumers must not parse this value.
    public let detail: String

    init(operation: Operation, detail: String) {
        self.operation = operation
        self.detail = detail
    }

}

extension OperationProgress {

    /// A mutating workflow activity that can emit progress.
    public enum Operation: Sendable, Equatable {

        /// Preparation of one required environment component.
        case preparingEnvironment(component: PreparationComponent, step: PreparationStep)

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

    /// An environment preparation activity that SwiftlyKit can report.
    public enum PreparationStep: Sendable {

        /// Download of data for an environment component.
        case downloading

        /// Verification of an environment component.
        case verifying

        /// Installation of an environment component.
        case installing

        /// Initialization of an installed environment component.
        case initializing

    }

}
