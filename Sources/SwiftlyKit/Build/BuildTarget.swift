/// A supported Linux cross-compilation target.
public enum BuildTarget: Sendable, Hashable {

    /// Selects a Linux Musl target for the specified architecture.
    case linux(LinuxArchitecture)

}

extension BuildTarget {
    
    var architecture: LinuxArchitecture {
        switch self {
            case .linux(let architecture): architecture
        }
    }
    
}
