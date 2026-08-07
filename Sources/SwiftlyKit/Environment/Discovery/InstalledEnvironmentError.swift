import Foundation

enum InstalledEnvironmentError: Error, Equatable, Sendable {
    
    case commandCouldNotRun(URL)
    case commandFailed(String)
    case invalidOutput
    
}
