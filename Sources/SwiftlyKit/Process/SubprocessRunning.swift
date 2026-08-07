protocol SubprocessRunning: Sendable {
    
    func run(
        _ command: SubprocessCommand,
        onOutput: SubprocessOutputHandler?
    ) async throws -> SubprocessResult
    
}

extension SubprocessRunning {
    
    func run(_ command: SubprocessCommand) async throws -> SubprocessResult {
        try await run(command, onOutput: nil)
    }
    
}
