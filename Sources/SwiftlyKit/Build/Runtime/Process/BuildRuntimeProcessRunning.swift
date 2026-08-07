protocol BuildRuntimeProcessRunning: Sendable {
    
    func run(
        _ command: BuildRuntimeCommand,
        onOutput: BuildRuntimeOutputHandler?
    ) async throws -> BuildRuntimeProcessResult
    
}
