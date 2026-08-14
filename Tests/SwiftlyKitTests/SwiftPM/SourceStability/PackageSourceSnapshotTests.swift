import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Package source snapshot")
struct PackageSourceSnapshotTests {

    @Test("Content, path, and executable mode changes alter source identity while timestamps do not")
    func semanticIdentity() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SourceSnapshot") { directory in
            let source = directory.appending(path: "Sources/Tool/main.swift")
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("print(1)\n".utf8).write(to: source)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: source.path(percentEncoded: false)
            )
            let initial = try PackageSourceSnapshot.capture(roots: [directory])

            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1)],
                ofItemAtPath: source.path(percentEncoded: false)
            )
            #expect(try PackageSourceSnapshot.capture(roots: [directory]) == initial)

            try Data("print(2)\n".utf8).write(to: source)
            #expect(try PackageSourceSnapshot.capture(roots: [directory]) != initial)

            try Data("print(1)\n".utf8).write(to: source)
            let renamed = source.deletingLastPathComponent().appending(path: "Main.swift")
            try FileManager.default.moveItem(at: source, to: renamed)
            #expect(try PackageSourceSnapshot.capture(roots: [directory]) != initial)

            try FileManager.default.moveItem(at: renamed, to: source)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: source.path(percentEncoded: false)
            )
            #expect(try PackageSourceSnapshot.capture(roots: [directory]) != initial)
        }
    }

    @Test("SwiftPM metadata and the selected scratch directory do not alter source identity")
    func ignoredBuildState() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SourceSnapshot") { directory in
            let source = directory.appending(path: "Sources/Tool/main.swift")
            let scratch = directory.appending(path: "custom-scratch", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("print(1)\n".utf8).write(to: source)
            let initial = try PackageSourceSnapshot.capture(
                roots: [directory],
                excluding: [scratch]
            )

            let ignoredDirectories = [
                directory.appending(path: ".build"),
                directory.appending(path: ".git"),
                directory.appending(path: ".swiftpm"),
                scratch
            ]
            for ignoredDirectory in ignoredDirectories {
                try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
                try Data("state".utf8).write(to: ignoredDirectory.appending(path: "state"))
                #expect(
                    try PackageSourceSnapshot.capture(
                        roots: [directory],
                        excluding: [scratch]
                    ) == initial,
                    "Unexpected source identity change for \(ignoredDirectory.lastPathComponent)."
                )
            }
        }
    }

    @Test("Package.resolved changes source identity")
    func resolvedDependencies() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SourceSnapshot") { directory in
            let resolved = directory.appending(path: "Package.resolved")
            try Data("{\"version\": 3, \"pins\": []}".utf8).write(to: resolved)
            let initial = try PackageSourceSnapshot.capture(roots: [directory])

            try Data("{\"version\": 3, \"pins\": [\"changed\"]}".utf8).write(to: resolved)

            #expect(try PackageSourceSnapshot.capture(roots: [directory]) != initial)
        }
    }

}
