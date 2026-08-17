import Foundation

/// One delegated child-process invocation observed before SwiftlyKit attempts to start it.
public struct CommandInvocation: Sendable {

    /// The executable that SwiftlyKit delegates to the child process.
    public let executable: URL

    /// The exact arguments passed to the executable.
    public let arguments: [String]

    /// The working directory passed to the child process, if one was set.
    public let workingDirectory: URL?

    /// The explicit environment passed to the child process.
    /// A `nil` value means that the child process inherits its environment.
    /// Marked sensitive values are replaced with `<redacted>`.
    public let environment: [String: String]?

    /// Creates a command value and redacts marked environment values.
    init(_ command: SubprocessCommand) {

        executable = command.executableURL
        arguments = command.arguments
        workingDirectory = command.workingDirectory

        guard var environment = command.environment else {
            self.environment = nil
            return
        }
        for name in command.sensitiveEnvironmentKeys where environment[name] != nil {
            environment[name] = SensitiveValueRedactor.placeholder
        }
        self.environment = environment
    }

}
