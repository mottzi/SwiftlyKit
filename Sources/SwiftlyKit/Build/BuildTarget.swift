/// Selects the platform and architecture for a build.
public enum BuildTarget: Sendable, Hashable {
    
    case linux(LinuxArchitecture)
    
}

extension BuildTarget {
    
    var architecture: LinuxArchitecture {
        switch self {
            case .linux(let architecture): architecture
        }
    }
    
}
