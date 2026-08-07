enum SubprocessOutput: Sendable {
    
    case standardOutput
    case standardError
    
}

typealias SubprocessOutputHandler = @Sendable (SubprocessOutput, String) async -> Void
