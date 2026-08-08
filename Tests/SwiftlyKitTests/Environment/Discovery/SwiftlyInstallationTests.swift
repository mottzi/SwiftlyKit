import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Swiftly installation")
struct SwiftlyInstallationTests {

    @Test("Configured Swiftly takes priority and canonicalizes its executable")
    func configuredBinPriority() async throws {

        try await withTemporaryDirectory { temporaryDirectory in
            let configuredTarget = temporaryDirectory.appending(path: "configured-target")
            let configuredBin = temporaryDirectory.appending(path: "configured-bin")
            let homeDirectory = temporaryDirectory.appending(path: "home")
            let homeBin = homeDirectory.appending(path: ".swiftly/bin")
            try FileManager.default.createDirectory(at: configuredTarget, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: homeBin, withIntermediateDirectories: true)
            let configuredExecutable = configuredTarget.appending(path: "swiftly")
            let homeExecutable = homeBin.appending(path: "swiftly")
            try makeExecutable(at: configuredExecutable)
            try makeExecutable(at: homeExecutable)
            try FileManager.default.createSymbolicLink(at: configuredBin, withDestinationURL: configuredTarget)

            let installation = try await SwiftlyInstallation.detect(
                environment: ["SWIFTLY_BIN_DIR": configuredBin.path],
                homeDirectory: homeDirectory,
                versionProbe: { _ in "1.1.3" }
            )

            #expect(installation?.executableURL == configuredExecutable.resolvingSymlinksInPath().standardizedFileURL)
        }
    }

    @Test("The official home location is used when no bin override is set")
    func homeFallback() async throws {

        try await withTemporaryDirectory { temporaryDirectory in
            let homeDirectory = temporaryDirectory.appending(path: "home")
            let executable = homeDirectory.appending(path: ".swiftly/bin/swiftly")
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try makeExecutable(at: executable)

            let installation = try await SwiftlyInstallation.detect(
                environment: [:],
                homeDirectory: homeDirectory,
                versionProbe: { _ in "1.0.0" }
            )

            #expect(installation?.executableURL == executable.standardizedFileURL)
        }
    }

    @Test("No qualifying executable returns nil without probing")
    func noExecutableReturnsNil() async throws {

        try await withTemporaryDirectory { temporaryDirectory in
            let result = try await SwiftlyInstallation.detect(
                environment: ["SWIFTLY_BIN_DIR": temporaryDirectory.appending(path: "configured").path],
                homeDirectory: temporaryDirectory.appending(path: "home"),
                versionProbe: { _ in fatalError("version probe must not run without a candidate") }
            )
            #expect(result == nil)
        }
    }

    @Test("Non-regular and non-executable candidates are ignored")
    func invalidCandidatesAreIgnored() async throws {

        try await withTemporaryDirectory { temporaryDirectory in
            let configuredBin = temporaryDirectory.appending(path: "configured")
            let homeBin = temporaryDirectory.appending(path: "home/.swiftly/bin")
            try FileManager.default.createDirectory(at: configuredBin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: homeBin, withIntermediateDirectories: true)
            let nonRegularCandidate = configuredBin.appending(path: "swiftly")
            try FileManager.default.createDirectory(at: nonRegularCandidate, withIntermediateDirectories: false)
            let nonExecutableCandidate = homeBin.appending(path: "swiftly")
            try Data("not executable".utf8).write(to: nonExecutableCandidate)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecutableCandidate.path)

            let result = try await SwiftlyInstallation.detect(
                environment: ["SWIFTLY_BIN_DIR": configuredBin.path],
                homeDirectory: temporaryDirectory.appending(path: "home"),
                versionProbe: { _ in fatalError("invalid candidates must not be probed") }
            )
            #expect(result == nil)
        }
    }

    @Test("Incompatible version output and probe failure map to incompatibleSwiftly")
    func incompatibleVersionOutput() async throws {

        try await withTemporaryDirectory { temporaryDirectory in
            let executable = temporaryDirectory.appending(path: "swiftly")
            try makeExecutable(at: executable)
            let environment = ["SWIFTLY_BIN_DIR": temporaryDirectory.path]

            for output in [
                "",
                "0.9.0",
                "1.2",
                "1.2.3-rc1",
                String(repeating: "9", count: 40) + ".0.0"
            ] {
                await #expect(throws: SwiftlyKitError.incompatibleSwiftly) {
                    try await SwiftlyInstallation.detect(
                        environment: environment,
                        homeDirectory: temporaryDirectory.appending(path: "home"),
                        versionProbe: { _ in output }
                    )
                }
            }

            await #expect(throws: SwiftlyKitError.incompatibleSwiftly) {
                try await SwiftlyInstallation.detect(
                    environment: environment,
                    homeDirectory: temporaryDirectory.appending(path: "home"),
                    versionProbe: { _ in throw SwiftlyKitError.developerToolsUnavailable }
                )
            }
        }
    }

    @Test("A selected candidate failure does not fall through to the home candidate")
    func selectedCandidateFailureDoesNotFallThrough() async throws {

        try await withTemporaryDirectory { temporaryDirectory in
            let configuredBin = temporaryDirectory.appending(path: "configured")
            let configuredExecutable = configuredBin.appending(path: "swiftly")
            let homeDirectory = temporaryDirectory.appending(path: "home")
            let homeExecutable = homeDirectory.appending(path: ".swiftly/bin/swiftly")
            try FileManager.default.createDirectory(at: configuredBin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: homeExecutable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try makeExecutable(at: configuredExecutable)
            try makeExecutable(at: homeExecutable)

            let recorder = ProbeRecorder()
            await #expect(throws: SwiftlyKitError.incompatibleSwiftly) {
                try await SwiftlyInstallation.detect(
                    environment: ["SWIFTLY_BIN_DIR": configuredBin.path],
                    homeDirectory: homeDirectory,
                    versionProbe: { url in
                        await recorder.record(url)
                        throw SwiftlyKitError.developerToolsUnavailable
                    }
                )
            }
            let probedURL = await recorder.value
            #expect(probedURL == configuredExecutable.standardizedFileURL)
        }
    }

    @Test("Cancellation remains CancellationError")
    func cancellationPreserved() async throws {

        try await withTemporaryDirectory { temporaryDirectory in
            let executable = temporaryDirectory.appending(path: "swiftly")
            try makeExecutable(at: executable)

            await #expect(throws: CancellationError.self) {
                try await SwiftlyInstallation.detect(
                    environment: ["SWIFTLY_BIN_DIR": temporaryDirectory.path],
                    homeDirectory: temporaryDirectory.appending(path: "home"),
                    versionProbe: { _ in throw CancellationError() }
                )
            }
        }
    }

    @Test("Live probe invokes an executable with --version and parses its output")
    func liveVersionProbe() async throws {

        try await withTemporaryDirectory { temporaryDirectory in
            let executable = temporaryDirectory.appending(path: "swiftly")
            try write(
                "#!/bin/sh\nif [ \"$1\" != \"--version\" ]; then exit 2; fi\nprintf ' 1.2.3\\n'\n",
                to: executable
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

            let installation = try await SwiftlyInstallation.detect(
                environment: ["SWIFTLY_BIN_DIR": temporaryDirectory.path],
                homeDirectory: temporaryDirectory.appending(path: "home"),
                versionProbe: { try await SwiftlyInstallation.liveVersionProbe(at: $0) }
            )

            #expect(installation?.executableURL == executable.standardizedFileURL)
        }
    }

}

private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SwiftlyKit-SwiftlyInstallation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

private actor ProbeRecorder {

    private(set) var value: URL?

    func record(_ url: URL) {
        value = url
    }

}

private func makeExecutable(at url: URL) throws {
    try write("#!/bin/sh\nexit 0\n", to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func write(_ value: String, to url: URL) throws {
    try Data(value.utf8).write(to: url)
}
