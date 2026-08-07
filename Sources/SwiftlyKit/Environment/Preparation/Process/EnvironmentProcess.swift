import Foundation
import Subprocess
import System

enum EnvironmentProcess {

    static let outputLimit = 256 * 1024

    static func run(_ command: EnvironmentCommand) async throws -> EnvironmentCommandResult {

        try Task.checkCancellation()

        do {
            let result = try await Subprocess.run(
                .path(FilePath(command.executableURL.path)),
                arguments: Arguments(command.arguments),
                environment: .inherit,
                workingDirectory: command.workingDirectory.map { FilePath($0.path) },
                platformOptions: .swiftlyKitProcess,
                output: .string(limit: outputLimit),
                error: .string(limit: outputLimit)
            )
            try Task.checkCancellation()
            return EnvironmentCommandResult(
                succeeded: result.terminationStatus.isSuccess,
                standardOutput: result.standardOutput,
                standardError: result.standardError
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw EnvironmentRuntimeError.commandCouldNotRun(command.executableURL)
        }

    }

}
