import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Build result")
struct BuildResultTests {

    @Test("Post-build publication uses the executable name and exact resource bundles")
    func publish() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-BuildResult") { directory in
            let build = directory.appending(path: "build", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
            let executable = build.appending(path: ".Tool.swiftlykit-stripped")
            try writeELF(to: executable, architecture: .arm64)
            let executableData = try Data(contentsOf: executable)
            let bundle = build.appending(path: "Package_Assets.resources", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
            try Data("asset".utf8).write(to: bundle.appending(path: "asset.txt"))
            let result = BuildResult(
                executable: executable,
                executableName: "Tool",
                resourceBundles: [bundle],
                architecture: .arm64
            )
            let destination = directory.appending(path: "Published", directoryHint: .isDirectory)

            let published = try await result.publish(to: destination)

            #expect(published.executable == destination.appending(path: "Tool"))
            #expect(published.executableName == "Tool")
            #expect(published.resourceBundles == [
                destination.appending(path: "Package_Assets.resources", directoryHint: .isDirectory)
            ])
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path())) == [
                "Tool",
                "Package_Assets.resources"
            ])
            #expect(try Data(contentsOf: published.executable) == executableData)
            #expect(try Data(
                contentsOf: destination.appending(path: "Package_Assets.resources/asset.txt")
            ) == Data("asset".utf8))
        }
    }

    @Test("Post-build publication maps an existing destination to the public error")
    func existingDestination() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-BuildResult") { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .x86_64)
            let result = BuildResult(
                executable: executable,
                executableName: "Tool",
                resourceBundles: [],
                architecture: .x86_64
            )
            let destination = directory.appending(path: "Published", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

            await #expect(throws: SwiftlyKitError.outputAlreadyExists(destination)) {
                try await result.publish(to: destination)
            }
        }
    }

    @Test("Post-build publication fills an existing empty directory")
    func existingEmptyDirectory() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-BuildResult") { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .x86_64)
            let result = BuildResult(
                executable: executable,
                executableName: "Tool",
                resourceBundles: [],
                architecture: .x86_64
            )
            let destination = directory.appending(path: "Published", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

            let published = try await result.publish(into: destination)

            #expect(published.executable == destination.appending(path: "Tool"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path()) == ["Tool"])
        }
    }

    @Test("Post-build publication preserves a selected directory that is no longer empty")
    func nonemptySelectedDirectory() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-BuildResult") { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .x86_64)
            let result = BuildResult(
                executable: executable,
                executableName: "Tool",
                resourceBundles: [],
                architecture: .x86_64
            )
            let destination = directory.appending(path: "Published", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let unrelatedFile = destination.appending(path: "unrelated.txt")
            try Data("keep".utf8).write(to: unrelatedFile)

            await #expect(throws: SwiftlyKitError.outputAlreadyExists(destination)) {
                try await result.publish(into: destination)
            }

            #expect(try Data(contentsOf: unrelatedFile) == Data("keep".utf8))
        }
    }

    @Test("Post-build publication revalidates the executable")
    func revalidatesExecutable() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-BuildResult") { directory in
            let executable = directory.appending(path: "Tool")
            try writeELF(to: executable, architecture: .arm64)
            let result = BuildResult(
                executable: executable,
                executableName: "Tool",
                resourceBundles: [],
                architecture: .arm64
            )
            try Data("changed".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: executable.path(percentEncoded: false)
            )
            let destination = directory.appending(path: "Published", directoryHint: .isDirectory)

            await #expect(throws: SwiftlyKitError.executableVerificationFailed(
                "The output is not an executable regular file."
            )) {
                try await result.publish(to: destination)
            }

            #expect(!FileManager.default.fileExists(atPath: destination.path()))
        }
    }

}
