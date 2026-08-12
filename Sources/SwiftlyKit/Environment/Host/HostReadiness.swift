/// Read-only readiness of the current host for SwiftlyKit operations.
public enum HostReadiness: Sendable, Equatable {

    case ready
    case developerToolsUnavailable
    case unsupportedHost

}

extension HostReadiness {

    func requireReady() throws {

        switch self {
            case .ready: return
            case .developerToolsUnavailable: throw SwiftlyKitError.developerToolsUnavailable
            case .unsupportedHost: throw SwiftlyKitError.unsupportedHost
        }
    }

}
