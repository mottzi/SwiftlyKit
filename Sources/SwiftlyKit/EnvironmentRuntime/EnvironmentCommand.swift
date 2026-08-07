import Foundation

/// A bounded command description shared by the environment adapters.
struct EnvironmentCommand: Equatable, Sendable {

    let executableURL: URL
    let arguments: [String]
    let workingDirectory: URL?

}
