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

/// Bounded output and termination state from one child process.
struct SubprocessResult: Equatable, Sendable {

    let succeeded: Bool
    let standardOutput: String
    let standardError: String

    var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

}

typealias SubprocessOutputHandler = @Sendable (CommandOutput.Stream, String) async -> Void

protocol SubprocessRunning: Sendable {

    func run(_ command: SubprocessCommand, onOutput: SubprocessOutputHandler?) async throws -> SubprocessResult

}

extension SubprocessRunning {

    func run(_ command: SubprocessCommand) async throws -> SubprocessResult {
        try await run(command, onOutput: nil)
    }

}
