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
