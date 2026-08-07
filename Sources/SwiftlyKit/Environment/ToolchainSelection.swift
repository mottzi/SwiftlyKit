/// Selects the Swift toolchain used for an operation.
public enum ToolchainSelection: Sendable, Hashable {
    
    case automatic
    case exact(SwiftVersion)
    
}
