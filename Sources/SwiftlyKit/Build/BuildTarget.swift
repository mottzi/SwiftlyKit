/// Selects the platform and architecture for a build.
public enum BuildTarget: Sendable, Hashable {
    
    case linux(LinuxArchitecture)
    
}
