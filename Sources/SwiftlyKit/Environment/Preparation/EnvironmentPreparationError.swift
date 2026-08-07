import Foundation

enum EnvironmentPreparationError: Error, Equatable, Sendable {

    case invalidDownloadURL
    case invalidHTTPResponse(Int)
    case downloadFailed
    case packageSignatureRejected
    case installationFailed(String)
    case commandCouldNotRun(URL)
    case swiftlyUnavailableAfterInstallation
    case unauthorizedMutationRequired

}
