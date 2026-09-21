/// A supported Linux cross-compilation target.
public enum BuildTarget: Sendable, Hashable, CaseIterable {

    /// Selects a Linux Musl target for the specified architecture.
    case linux(LinuxArchitecture)

}

extension BuildTarget {

    /// All supported cross-compilation targets.
    public static var allCases: [Self] {
        LinuxArchitecture.allCases.map { .linux($0) }
    }
    
}

extension BuildTarget {

    var architecture: LinuxArchitecture {
        switch self {
            case .linux(let architecture): architecture
        }
    }
    
}
