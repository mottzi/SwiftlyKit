/// Captured command output. Environment values are deliberately not retained.
struct EnvironmentCommandResult: Equatable, Sendable {

    let succeeded: Bool
    let standardOutput: String
    let standardError: String

    var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

}
