@testable import SwiftlyKit

actor RecordingSubprocessRunner: SubprocessRunning {

    private var pendingResults: [SubprocessResult]
    private(set) var commands: [SubprocessCommand] = []

    init(results: [SubprocessResult]) {
        self.pendingResults = results
    }

    func run(_ command: SubprocessCommand, onOutput: SubprocessOutputHandler?) async throws -> SubprocessResult {

        commands.append(command)

        guard !pendingResults.isEmpty else { throw RecordingSubprocessRunnerError.unexpectedCommand(command) }

        let result = pendingResults.removeFirst()

        if let onOutput {
            if !result.standardOutput.isEmpty {
                await onOutput(.standardOutput, result.standardOutput)
            }
            if !result.standardError.isEmpty {
                await onOutput(.standardError, result.standardError)
            }
        }

        return result
    }

}

extension SubprocessResult {

    static func success(output: String = "", standardError: String = "") -> SubprocessResult {
        SubprocessResult(succeeded: true, standardOutput: output, standardError: standardError)
    }

    static func failure(output: String = "", standardError: String = "") -> SubprocessResult {
        SubprocessResult(succeeded: false, standardOutput: output, standardError: standardError)
    }

}

private enum RecordingSubprocessRunnerError: Error {
    case unexpectedCommand(SubprocessCommand)
}
