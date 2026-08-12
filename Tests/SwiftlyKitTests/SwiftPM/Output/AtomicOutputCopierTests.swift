import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Atomic build output copying")
struct AtomicOutputCopierTests {

    @Test("Copies bytes and refuses replacement")
    func copyNoReplace() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let source = directory.appending(path: "source")
            let output = directory.appending(path: "output")
            try Data("first".utf8).write(to: source)
            #expect(try await AtomicOutputCopier.copy(source, to: output) == output)
            #expect(try Data(contentsOf: output) == Data("first".utf8))

            try Data("second".utf8).write(to: source)
            await #expect(throws: SwiftPMError.outputAlreadyExists(output)) {
                try await AtomicOutputCopier.copy(source, to: output)
            }
            #expect(try Data(contentsOf: output) == Data("first".utf8))
        }
    }

    @Test("Concurrent copies cannot replace the winning output")
    func concurrentCopies() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let first = directory.appending(path: "first")
            let second = directory.appending(path: "second")
            let output = directory.appending(path: "output")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)

            let attempts = await withTaskGroup(of: CopyAttempt.self) { group in
                for source in [first, second] {
                    group.addTask {
                        do {
                            _ = try await AtomicOutputCopier.copy(source, to: output)
                            return .copied
                        }
                        catch let error as SwiftPMError { return .rejected(error) }
                        catch { return .unexpected }
                    }
                }

                var attempts: [CopyAttempt] = []
                for await attempt in group {
                    attempts.append(attempt)
                }
                return attempts
            }

            #expect(attempts.filter(\.wasCopied).count == 1)
            #expect(attempts.filter(\.wasRejectedAsExisting).count == 1)
            let bytes = try Data(contentsOf: output)
            #expect(bytes == Data("first".utf8) || bytes == Data("second".utf8))
        }
    }

    @Test("Prepares only the staged copy before publication")
    func preparedCopy() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let source = directory.appending(path: "source")
            let output = directory.appending(path: "output")
            try Data("source".utf8).write(to: source)

            let result = try await AtomicOutputCopier.copy(
                source,
                to: output,
                prepare: { stagedCopy in
                    #expect(stagedCopy != source)
                    #expect(stagedCopy != output)
                    try Data("prepared".utf8).write(to: stagedCopy)
                }
            )

            #expect(result == output)
            #expect(try Data(contentsOf: source) == Data("source".utf8))
            #expect(try Data(contentsOf: output) == Data("prepared".utf8))
        }
    }

    @Test("Preparation failure publishes nothing and removes staging")
    func preparationFailure() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let source = directory.appending(path: "source")
            let output = directory.appending(path: "output")
            try Data("source".utf8).write(to: source)

            await #expect(throws: CopyPreparationError.failed) {
                try await AtomicOutputCopier.copy(
                    source,
                    to: output,
                    prepare: { _ in throw CopyPreparationError.failed }
                )
            }

            #expect(!FileManager.default.fileExists(atPath: output.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source"])
        }
    }

    @Test("Owned output can be replaced atomically")
    func replaceOwnedOutput() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let source = directory.appending(path: "source")
            let output = directory.appending(path: "output")
            try Data("first".utf8).write(to: output)
            try Data("second".utf8).write(to: source)

            #expect(try await AtomicOutputCopier.copy(
                source,
                to: output,
                replacingExisting: true
            ) == output)
            #expect(try Data(contentsOf: output) == Data("second".utf8))
        }
    }

}

private enum CopyPreparationError: Error {
    case failed
}

private enum CopyAttempt {
    case copied
    case rejected(SwiftPMError)
    case unexpected

    var wasCopied: Bool {
        if case .copied = self { return true }
        return false
    }

    var wasRejectedAsExisting: Bool {
        if case .rejected(.outputAlreadyExists) = self { return true }
        return false
    }
}
