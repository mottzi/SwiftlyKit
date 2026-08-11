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
                environment: Self.processEnvironment(command.environment),
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

    private static func processEnvironment(_ environment: [String: String]?) -> Environment {

        guard let environment else { return .inherit }

        return .custom(environment.map { key, value in
            Array("\(key)=\(value)\0".utf8)
        })
    }

}

extension LiveSubprocessRunner {

    private func collect(
        _ sequence: SubprocessOutputSequence,
        stream: CommandOutputChunk.Stream,
        handler: SubprocessOutputHandler?
    ) async throws -> String {

        var collected = ""
        var decoder = UTF8StreamDecoder()

        for try await buffer in sequence {
            try Task.checkCancellation()

            let chunk = decoder.decode(buffer)
            guard !chunk.isEmpty else { continue }

            collected.append(chunk)

            if collected.utf8.count > Self.outputLimit {
                collected = String(collected.suffix(Self.outputLimit / 2))
            }

            await handler?(stream, chunk)
        }

        let finalChunk = decoder.finish()
        if !finalChunk.isEmpty {
            collected.append(finalChunk)
            await handler?(stream, finalChunk)
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

    private static let outputLimit = 1_048_576

}

private struct UTF8StreamDecoder {

    private var pending: [UInt8] = []

    mutating func decode(_ buffer: SubprocessOutputSequence.Buffer) -> String {

        var bytes = pending
        bytes.append(contentsOf: buffer.withUnsafeBytes { Array($0) })

        let suffixCount = Self.incompleteScalarSuffixCount(in: bytes)
        if suffixCount > 0 {
            pending = Array(bytes.suffix(suffixCount))
            bytes.removeLast(suffixCount)
        } else {
            pending.removeAll(keepingCapacity: true)
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func finish() -> String {

        defer { pending.removeAll(keepingCapacity: true) }
        return String(decoding: pending, as: UTF8.self)
    }

}

extension UTF8StreamDecoder {

    private static func incompleteScalarSuffixCount(in bytes: [UInt8]) -> Int {

        guard !bytes.isEmpty else { return 0 }

        var leadingIndex = bytes.index(before: bytes.endIndex)
        while leadingIndex > bytes.startIndex, isContinuation(bytes[leadingIndex]) {
            leadingIndex = bytes.index(before: leadingIndex)
        }

        let expectedCount = scalarByteCount(startingWith: bytes[leadingIndex])
        guard expectedCount > 1 else { return 0 }

        let actualCount = bytes.distance(from: leadingIndex, to: bytes.endIndex)
        guard actualCount < expectedCount else { return 0 }

        let continuationBytes = bytes[bytes.index(after: leadingIndex)...]
        guard continuationBytes.allSatisfy(isContinuation) else { return 0 }
        guard isValidPartialScalar(bytes[leadingIndex...]) else { return 0 }

        return actualCount
    }

    private static func scalarByteCount(startingWith byte: UInt8) -> Int {
        switch byte {
            case 0xC2...0xDF: 2
            case 0xE0...0xEF: 3
            case 0xF0...0xF4: 4
            default: 1
        }
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        (0x80...0xBF).contains(byte)
    }

    private static func isValidPartialScalar(_ bytes: ArraySlice<UInt8>) -> Bool {

        guard bytes.count > 1, let leadingByte = bytes.first else { return true }
        let secondByte = bytes[bytes.index(after: bytes.startIndex)]

        switch leadingByte {
            case 0xE0: return secondByte >= 0xA0
            case 0xED: return secondByte <= 0x9F
            case 0xF0: return secondByte >= 0x90
            case 0xF4: return secondByte <= 0x8F
            default: return true
        }
    }

}
