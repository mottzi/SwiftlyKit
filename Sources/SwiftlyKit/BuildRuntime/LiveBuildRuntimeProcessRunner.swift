import Foundation
import Subprocess
import System

struct LiveBuildRuntimeProcessRunner: BuildRuntimeProcessRunning {
    
    func run(
        _ command: BuildRuntimeCommand,
        onOutput: BuildRuntimeOutputHandler?
    ) async throws -> BuildRuntimeProcessResult {
        
        try Task.checkCancellation()
        let sink = BuildRuntimeOutputSink(handler: onOutput)
        do {
            let result = try await Subprocess.run(
                .path(FilePath(command.executable.path)),
                arguments: Arguments(command.arguments),
                environment: .custom(command.environment.map { key, value in
                    Array("\(key)=\(value)\0".utf8)
                }),
                workingDirectory: FilePath(command.workingDirectory.path),
                platformOptions: .swiftlyKitProcess,
                input: .none,
                output: .sequence,
                error: .sequence
            ) { execution in
                async let standardOutput = collect(
                    execution.standardOutput,
                    stream: .standardOutput,
                    sink: sink
                )
                async let standardError = collect(
                    execution.standardError,
                    stream: .standardError,
                    sink: sink
                )
                return try await (standardOutput, standardError)
            }
            try Task.checkCancellation()
            return BuildRuntimeProcessResult(
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

extension LiveBuildRuntimeProcessRunner {

    private func collect(
        _ sequence: SubprocessOutputSequence,
        stream: BuildRuntimeOutputStream,
        sink: BuildRuntimeOutputSink
    ) async throws -> String {
        
        var collected = ""
        for try await chunk in sequence.strings() {
            try Task.checkCancellation()
            collected.append(chunk)
            if collected.utf8.count > 1_048_576 {
                collected = String(collected.suffix(524_288))
            }
            await sink.emit(stream, chunk)
        }
        return collected
    }
    
}
