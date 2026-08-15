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

    @Test("Preserves line breaks in captured and streamed output")
    func lineBreaksArePreserved() async throws {

        let recorder = OutputRecorder()
        let command = SubprocessCommand(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", "printf 'first\\nsecond\\n'"]
        )

        let result = try await LiveSubprocessRunner().run(
            command,
            onOutput: { stream, text in
                await recorder.record(stream, text)
            }
        )

        let expected = "first\nsecond\n"
        #expect(result.succeeded)
        #expect(result.standardOutput == expected)
        #expect(await recorder.output[.standardOutput] == expected)
    }

    @Test("Preserves UTF-8 scalars split across output buffers")
    func splitUTF8ScalarIsPreserved() async throws {

        let recorder = OutputRecorder()
        let command = SubprocessCommand(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", "printf '\\303'; sleep 0.05; printf '\\251\\n'"]
        )

        let result = try await LiveSubprocessRunner().run(
            command,
            onOutput: { stream, text in
                await recorder.record(stream, text)
            }
        )

        let expected = "é\n"
        #expect(result.succeeded)
        #expect(result.standardOutput == expected)
        #expect(await recorder.output[.standardOutput] == expected)
    }

    @Test("Redacts sensitive environment values from captured and streamed output")
    func sensitiveValuesAreRedacted() async throws {

        let recorder = OutputRecorder()
        let command = SubprocessCommand(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: [
                "-c",
                "printf 'out:%s' \"$TOKEN\"; printf 'err:%s' \"$TOKEN\" >&2"
            ],
            environment: ["TOKEN": "private-value"],
            sensitiveEnvironmentKeys: ["TOKEN"]
        )

        let result = try await LiveSubprocessRunner().run(
            command,
            onOutput: { stream, text in
                await recorder.record(stream, text)
            }
        )

        #expect(result.standardOutput == "out:<redacted>")
        #expect(result.standardError == "err:<redacted>")
        #expect(await recorder.output[.standardOutput] == "out:<redacted>")
        #expect(await recorder.output[.standardError] == "err:<redacted>")
        #expect(!result.combinedOutput.contains("private-value"))
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
        #expect(streamed.utf8.count == 1_200_011)
        #expect(streamed.utf8.filter { $0 == 0x0A }.count == 11)
        #expect(result.standardOutput.utf8.count <= 1_048_576)
        #expect(streamed.hasSuffix(result.standardOutput))
    }

    @Test("Cancellation terminates child processes in the subprocess group")
    func cancellationTerminatesProcessGroup() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-Subprocess") { directory in
            let sentinel = directory.appending(path: "child-survived")
            let command = SubprocessCommand(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    "(sleep 0.4; /usr/bin/touch '\(sentinel.path(percentEncoded: false))') & wait"
                ]
            )
            let task = Task { try await LiveSubprocessRunner().run(command, onOutput: nil) }

            try await Task.sleep(for: .milliseconds(50))
            task.cancel()

            await #expect(throws: CancellationError.self) {
                try await task.value
            }
            try await Task.sleep(for: .milliseconds(500))
            #expect(!FileManager.default.fileExists(atPath: sentinel.path(percentEncoded: false)))
        }
    }

}

private actor OutputRecorder {

    private(set) var output: [CommandOutputChunk.Stream: String] = [:]

    func record(_ stream: CommandOutputChunk.Stream, _ text: String) {
        output[stream, default: ""].append(text)
    }

}
