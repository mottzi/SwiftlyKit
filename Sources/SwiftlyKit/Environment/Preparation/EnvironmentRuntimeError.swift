import Foundation

enum EnvironmentRuntimeError: Error, Equatable, Sendable {

    case invalidDownloadURL
    case invalidHTTPResponse(Int)
    case downloadFailed
    case packageSignatureRejected
    case installationFailed(String)
    case inspectionFailed(String)
    case invalidInspectionOutput
    case commandCouldNotRun(URL)
    case swiftlyUnavailableAfterInstallation
    case unauthorizedMutationRequired

}
