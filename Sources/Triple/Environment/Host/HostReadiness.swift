/// Read-only readiness of the current host for Triple operations.
public enum HostReadiness: Sendable, Equatable {

    case ready
    case developerToolsUnavailable
    case unsupportedHost

}

extension HostReadiness {

    func requireReady() throws {

        switch self {
            case .ready: return
            case .developerToolsUnavailable: throw TripleError.developerToolsUnavailable
            case .unsupportedHost: throw TripleError.unsupportedHost
        }
    }

}
