import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Swiftly installation")
struct SwiftlyInstallationTests {

    @Test("A missing executable returns nil without probing")
    func noExecutableReturnsNil() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftlyInstallation") { directory in
            let result = try await SwiftlyInstallation.detect(
                storage: .directory(directory.appending(path: "storage")),
                versionProbe: { _ in fatalError("The version probe must not run without an executable.") }
            )

            #expect(result == nil)
        }
    }

    @Test("Non-regular and non-executable files are ignored")
    func invalidExecutablesAreIgnored() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftlyInstallation") { directory in
            let directoryStorage = directory.appending(path: "directory-storage")
            try FileManager.default.createDirectory(
                at: directoryStorage.appending(path: "bin/swiftly"),
                withIntermediateDirectories: true
            )

            let fileStorage = directory.appending(path: "file-storage")
            let nonExecutable = fileStorage.appending(path: "bin/swiftly")
            try FileManager.default.createDirectory(
                at: nonExecutable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("not executable".utf8).write(to: nonExecutable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: nonExecutable.path(percentEncoded: false)
            )

            for storage in [directoryStorage, fileStorage] {
                let result = try await SwiftlyInstallation.detect(
                    storage: .directory(storage),
                    versionProbe: { _ in fatalError("An invalid executable must not be probed.") }
                )
                #expect(result == nil)
            }
        }
    }

    @Test("Incompatible version output and probe failure map to incompatibleSwiftly")
    func incompatibleVersionOutput() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftlyInstallation") { directory in
            let storage = directory.appending(path: "storage")
            try makeInstallationTestExecutable(at: storage.appending(path: "bin/swiftly"))

            let outputs = [
                "",
                "0.9.0",
                "1.2",
                "1.2.3-rc1",
                String(repeating: "9", count: 40) + ".0.0"
            ]
            for output in outputs {
                await #expect(throws: SwiftlyKitError.incompatibleSwiftly) {
                    try await SwiftlyInstallation.detect(
                        storage: .directory(storage),
                        versionProbe: { _ in output }
                    )
                }
            }

            await #expect(throws: SwiftlyKitError.incompatibleSwiftly) {
                try await SwiftlyInstallation.detect(
                    storage: .directory(storage),
                    versionProbe: { _ in throw SwiftlyKitError.developerToolsUnavailable }
                )
            }
        }
    }

    @Test("Cancellation remains CancellationError")
    func cancellationPreserved() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftlyInstallation") { directory in
            let storage = directory.appending(path: "storage")
            try makeInstallationTestExecutable(at: storage.appending(path: "bin/swiftly"))

            await #expect(throws: CancellationError.self) {
                try await SwiftlyInstallation.detect(
                    storage: .directory(storage),
                    versionProbe: { _ in throw CancellationError() }
                )
            }
        }
    }

    @Test("The live probe invokes the selected executable with --version")
    func liveVersionProbe() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-SwiftlyInstallation") { directory in
            let storage = directory.appending(path: "storage")
            let executable = storage.appending(path: "bin/swiftly")
            try makeInstallationTestExecutable(
                at: executable,
                contents: "#!/bin/sh\nif [ \"$1\" != \"--version\" ]; then exit 2; fi\nprintf ' 1.2.3\\n'\n"
            )

            let installation = try await SwiftlyInstallation.detect(
                storage: .directory(storage)
            )

            #expect(installation?.executableURL == executable.standardizedFileURL)
        }
    }

}

private func makeInstallationTestExecutable(
    at url: URL,
    contents: String = "#!/bin/sh\nexit 0\n"
) throws {

    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path(percentEncoded: false)
    )
}
