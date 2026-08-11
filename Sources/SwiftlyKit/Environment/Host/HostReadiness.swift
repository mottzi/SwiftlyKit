enum HostReadiness {

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
