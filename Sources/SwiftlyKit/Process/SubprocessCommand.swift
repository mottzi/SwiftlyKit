import Foundation

/// A complete description of one child process invocation.
struct SubprocessCommand: Equatable, Sendable {
    
    let executableURL: URL
    let arguments: [String]
    let workingDirectory: URL?
    let environment: [String: String]?
    
    init(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
    
}
