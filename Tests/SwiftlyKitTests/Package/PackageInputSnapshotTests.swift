import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Package input snapshot")
struct PackageInputSnapshotTests {

    @Test("Invalid package roots are rejected")
    func invalidPackageRoots() throws {

        let nonFileURL = URL(string: "https://example.com/package")!
        #expect(throws: SwiftlyKitError.invalidPackageRoot(nonFileURL)) {
            try PackageInputSnapshot.capture(at: nonFileURL)
        }

        try withTemporaryDirectory { temporaryDirectory in
            let missingRoot = temporaryDirectory.appending(path: "missing")
            #expect(throws: SwiftlyKitError.invalidPackageRoot(missingRoot)) {
                try PackageInputSnapshot.capture(at: missingRoot)
            }

            try FileManager.default.createDirectory(
                at: temporaryDirectory.appending(path: "no-manifest"),
                withIntermediateDirectories: false
            )
            let noManifestRoot = temporaryDirectory.appending(path: "no-manifest")
            #expect(throws: SwiftlyKitError.invalidPackageRoot(noManifestRoot)) {
                try PackageInputSnapshot.capture(at: noManifestRoot)
            }
        }
    }

    @Test("Package roots are canonicalized and two-component tools versions normalize")
    func canonicalRootAndToolsVersion() throws {

        try withTemporaryDirectory { temporaryDirectory in
            let realRoot = temporaryDirectory.appending(path: "real")
            try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: false)
            try write(
                "\n// leading comment\n  //\tSWIFT-TOOLS-VERSION:\t6.2; ignored\nimport PackageDescription\n",
                to: realRoot.appending(path: "Package.swift")
            )

            let symlinkRoot = temporaryDirectory.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: realRoot)
            let snapshot = try PackageInputSnapshot.capture(at: symlinkRoot)

            #expect(snapshot.packageRoot == realRoot.resolvingSymlinksInPath().standardizedFileURL)
            #expect(snapshot.toolsVersion == SwiftVersion(major: 6, minor: 2, patch: 0))
            #expect(snapshot.swiftVersion == nil)
        }
    }

    @Test("Pre-six later directives require the first non-whitespace line")
    func preSixDirectivePlacement() throws {

        try withTemporaryDirectory { temporaryDirectory in
            let manifestURL = temporaryDirectory.appending(path: "Package.swift")
            try write("// swift-tools-version: 5.9\n", to: manifestURL)
            let snapshot = try PackageInputSnapshot.capture(at: temporaryDirectory)
            #expect(snapshot.toolsVersion == SwiftVersion(major: 5, minor: 9, patch: 0))

            try write(
                "// a leading comment\n// swift-tools-version: 5.9\n",
                to: manifestURL
            )
            #expect(throws: SwiftlyKitError.unsupportedToolsVersion(
                SwiftVersion(major: 5, minor: 9, patch: 0)
            )) {
                try PackageInputSnapshot.capture(at: temporaryDirectory)
            }
        }
    }

    @Test("Nearest parent Swift version files are trimmed and package files override them")
    func swiftVersionLookup() throws {

        try withTemporaryDirectory { temporaryDirectory in
            let parent = temporaryDirectory.appending(path: "parent")
            let packageRoot = parent.appending(path: "package")
            try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
            try write("// swift-tools-version: 6.0\n", to: packageRoot.appending(path: "Package.swift"))

            let parentVersionURL = parent.appending(path: ".swift-version")
            try write("\n\t 6.1.2 \n", to: parentVersionURL)
            let parentSnapshot = try PackageInputSnapshot.capture(at: packageRoot)
            #expect(parentSnapshot.swiftVersion == "6.1.2")

            let packageVersionURL = packageRoot.appending(path: ".swift-version")
            try write(" 6.2.0\n", to: packageVersionURL)
            let packageSnapshot = try PackageInputSnapshot.capture(at: packageRoot)
            #expect(packageSnapshot.swiftVersion == "6.2.0")
        }
    }

    @Test("Missing and malformed tools directives are rejected")
    func malformedToolsVersion() throws {

        try withTemporaryDirectory { temporaryDirectory in
            let manifestURL = temporaryDirectory.appending(path: "Package.swift")
            try write("import PackageDescription\n", to: manifestURL)
            #expect(throws: SwiftlyKitError.malformedToolsVersion) {
                try PackageInputSnapshot.capture(at: temporaryDirectory)
            }

            try write("// swift-tools-version: 6\n", to: manifestURL)
            #expect(throws: SwiftlyKitError.malformedToolsVersion) {
                try PackageInputSnapshot.capture(at: temporaryDirectory)
            }
        }
    }

    @Test("A non-regular Swift version entry is rejected")
    func nonRegularSwiftVersionFile() throws {

        try withTemporaryDirectory { temporaryDirectory in
            let manifestRoot = temporaryDirectory.appending(path: "package")
            try FileManager.default.createDirectory(at: manifestRoot, withIntermediateDirectories: false)
            try write("// swift-tools-version: 6.0\n", to: manifestRoot.appending(path: "Package.swift"))
            try FileManager.default.createDirectory(
                at: manifestRoot.appending(path: ".swift-version"),
                withIntermediateDirectories: false
            )

            #expect(throws: SwiftlyKitError.staleAssessment) {
                try PackageInputSnapshot.capture(at: manifestRoot)
            }
        }
    }

    @Test("Unchanged inputs revalidate")
    func unchangedInputsRevalidate() throws {

        try withTemporaryDirectory { packageRoot in
            try write("// swift-tools-version: 6.0\n", to: packageRoot.appending(path: "Package.swift"))
            try write("6.2.1\n", to: packageRoot.appending(path: ".swift-version"))

            let snapshot = try PackageInputSnapshot.capture(at: packageRoot)

            try snapshot.validateCurrent()
        }
    }

    @Test("Semantically equivalent byte changes invalidate a snapshot")
    func byteChangesInvalidateSnapshot() throws {

        try withTemporaryDirectory { packageRoot in
            let manifestURL = packageRoot.appending(path: "Package.swift")
            let swiftVersionURL = packageRoot.appending(path: ".swift-version")
            try write("// swift-tools-version: 6.0\n", to: manifestURL)
            try write("6.2.1\n", to: swiftVersionURL)

            let manifestSnapshot = try PackageInputSnapshot.capture(at: packageRoot)
            try write("// swift-tools-version: 6.0\n// comment\n", to: manifestURL)
            #expect(throws: SwiftlyKitError.staleAssessment) {
                try manifestSnapshot.validateCurrent()
            }

            try write("// swift-tools-version: 6.0\n", to: manifestURL)
            let versionSnapshot = try PackageInputSnapshot.capture(at: packageRoot)
            try write(" 6.2.1 \n", to: swiftVersionURL)
            #expect(throws: SwiftlyKitError.staleAssessment) {
                try versionSnapshot.validateCurrent()
            }
        }
    }

    @Test("Changing the selected Swift version source invalidates a snapshot")
    func swiftVersionSourceChangeInvalidatesSnapshot() throws {

        try withTemporaryDirectory { temporaryDirectory in
            let packageRoot = temporaryDirectory.appending(path: "package")
            try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: false)
            try write("// swift-tools-version: 6.0\n", to: packageRoot.appending(path: "Package.swift"))
            try write("6.2.1\n", to: temporaryDirectory.appending(path: ".swift-version"))
            let snapshot = try PackageInputSnapshot.capture(at: packageRoot)

            try write("6.2.1\n", to: packageRoot.appending(path: ".swift-version"))

            #expect(throws: SwiftlyKitError.staleAssessment) {
                try snapshot.validateCurrent()
            }
        }
    }

}

@Test("Swift version parsing rejects non-semantic selectors")
func strictSwiftVersionParsing() {

    #expect(SwiftVersion(parsing: "6.2") == SwiftVersion(major: 6, minor: 2, patch: 0))
    #expect(SwiftVersion(parsing: "6.2.1") == SwiftVersion(major: 6, minor: 2, patch: 1))

    let values = [
        "",
        "6",
        "6.",
        ".2",
        "6..2",
        "+6.2",
        "6.-2",
        "6.2-rc1",
        "6.2+build",
        "6.2.1.0",
        String(repeating: "9", count: 40) + ".0"
    ]
    for value in values {
        #expect(SwiftVersion(parsing: value) == nil)
    }
}

private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SwiftlyKit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

private func write(_ value: String, to url: URL) throws {
    try Data(value.utf8).write(to: url)
}
