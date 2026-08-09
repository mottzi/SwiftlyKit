import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Subprocess runner")
struct LiveSubprocessRunnerTests {

    @Test("Captures both streams and awaits output delivery")
    func captureAndStreamOutput() async throws {

        let recorder = OutputRecorder()
        let command = SubprocessCommand(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", "printf standard; printf diagnostic >&2"]
        )

        let result = try await LiveSubprocessRunner().run(
            command,
            onOutput: { stream, text in
                await recorder.record(stream, text)
            }
        )

        #expect(result.succeeded)
        #expect(result.standardOutput == "standard")
        #expect(result.standardError == "diagnostic")
        let output = await recorder.output
        #expect(output[.standardOutput] == "standard")
        #expect(output[.standardError] == "diagnostic")
    }

    @Test("Bounds retained output without truncating streamed output")
    func boundedCollection() async throws {

        let recorder = OutputRecorder()
        let command = SubprocessCommand(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: [
                "-c",
                "/usr/bin/yes x | /usr/bin/tr -d '\\n' | /usr/bin/head -c 1200000 | /usr/bin/fold -w 100000"
            ]
        )

        let result = try await LiveSubprocessRunner().run(
            command,
            onOutput: { stream, text in await recorder.record(stream, text) }
        )

        let streamed = await recorder.output[.standardOutput] ?? ""
        #expect(result.succeeded)
        #expect(streamed.utf8.count == 1_200_000)
        #expect(result.standardOutput.utf8.count <= LiveSubprocessRunner.outputLimit)
        #expect(streamed.hasSuffix(result.standardOutput))
    }

    @Test("Cancellation terminates child processes in the subprocess group")
    func cancellationTerminatesProcessGroup() async throws {

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SwiftlyKit-Subprocess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appending(path: "child-survived")
        let command = SubprocessCommand(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: [
                "-c",
                "(sleep 0.4; /usr/bin/touch '\(sentinel.path)') & wait"
            ]
        )
        let task = Task { try await LiveSubprocessRunner().run(command, onOutput: nil) }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

}

private actor OutputRecorder {

    private(set) var output: [OutputStream: String] = [:]

    func record(_ stream: SubprocessOutput, _ text: String) {

        let key: OutputStream = switch stream {
            case .standardOutput: .standardOutput
            case .standardError: .standardError
        }
        output[key, default: ""].append(text)
    }

    enum OutputStream: Hashable {
        case standardOutput
        case standardError
    }

}
