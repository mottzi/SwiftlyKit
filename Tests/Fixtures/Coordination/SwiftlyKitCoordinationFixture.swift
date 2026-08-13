import Foundation
import SwiftlyKit

@main
/// Test-only sibling process for public coordination behavior.
struct SwiftlyKitCoordinationFixture {

    static func main() async throws {

        guard CommandLine.arguments.count == 4 else { return }

        let packageRoot = URL(filePath: CommandLine.arguments[1])
        let startedFile = URL(filePath: CommandLine.arguments[2])
        let outcomeFile = URL(filePath: CommandLine.arguments[3])
        try Data().write(to: startedFile)

        let outcome: String
        do {
            _ = try await SwiftlyKit.build(packageRoot)
            outcome = "unexpected-success"
        } catch SwiftlyKitError.invalidPackageRoot {
            outcome = "invalid-package-root"
        } catch {
            outcome = "unexpected-error"
        }

        try Data(outcome.utf8).write(to: outcomeFile)
    }

}
