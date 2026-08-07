/// Trustworthy progress for a current operation, component, or activity.
public struct OperationProgress: Sendable {
    
    public enum Operation: Sendable, Hashable {
        
        case preparingEnvironment
        case resolvingDependencies
        case building
        case stripping
        case publishing
        
    }
    
    public let operation: Operation
    public let component: PreparationComponent?
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
