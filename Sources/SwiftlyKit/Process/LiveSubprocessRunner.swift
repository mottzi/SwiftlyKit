import Foundation
import Subprocess
import System

/// The sole adapter between SwiftlyKit operations and swift-subprocess.
struct LiveSubprocessRunner: SubprocessRunning {

    func run(_ command: SubprocessCommand, onOutput: SubprocessOutputHandler?) async throws -> SubprocessResult {

        try Task.checkCancellation()

        do {
            let result = try await Subprocess.run(
                .path(FilePath(command.executableURL.path)),
                arguments: Arguments(command.arguments),
                environment: processEnvironment(command.environment),
                workingDirectory: command.workingDirectory.map { FilePath($0.path) },
                platformOptions: Self.processPlatformOptions,
                input: .none,
                output: .sequence,
                error: .sequence
            ) { execution in
                async let standardOutput = collect(execution.standardOutput, stream: .standardOutput, handler: onOutput)
                async let standardError = collect(execution.standardError, stream: .standardError, handler: onOutput)
                return try await (standardOutput, standardError)
            }

            try Task.checkCancellation()

            return SubprocessResult(
                succeeded: result.terminationStatus.isSuccess,
                standardOutput: result.closureResult.0,
                standardError: result.closureResult.1
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

}

extension LiveSubprocessRunner {

    private func processEnvironment(_ environment: [String: String]?) -> Environment {

        guard let environment else { return .inherit }

        return .custom(environment.map { key, value in
            Array("\(key)=\(value)\0".utf8)
        })
    }

    private func collect(
        _ sequence: SubprocessOutputSequence,
        stream: CommandOutput.Stream,
        handler: SubprocessOutputHandler?
    ) async throws -> String {

        var collected = ""

        for try await chunk in sequence.strings() {
            try Task.checkCancellation()

            collected.append(chunk)

            if collected.utf8.count > Self.outputLimit {
                collected = String(collected.suffix(Self.outputLimit / 2))
            }

            await handler?(stream, chunk)
        }

        return collected
    }

}

extension LiveSubprocessRunner {

    private static let processPlatformOptions: PlatformOptions = {
        var options = PlatformOptions()
        options.createSession = true
        options.teardownSequence = [
            .gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(1))
        ]
        return options
    }()

    static let outputLimit = 1_048_576

}
