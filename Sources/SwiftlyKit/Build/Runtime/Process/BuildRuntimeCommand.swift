import Foundation

struct BuildRuntimeCommand: Equatable, Sendable {
    
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL
    let environment: [String: String]
    
}
