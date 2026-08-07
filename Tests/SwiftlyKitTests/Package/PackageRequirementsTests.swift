import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Package requirements")
struct PackageRequirementsTests {
    @Test("Invalid package roots are rejected")
    func invalidPackageRoots() throws {
        let nonFileURL = URL(string: "https://example.com/package")!
        #expect(throws: PackageRequirements.LoadingError.invalidPackageRoot(nonFileURL)) {
            try PackageRequirements.load(at: nonFileURL)
        }
        
        try withTemporaryDirectory { temporaryDirectory in
            let missingRoot = temporaryDirectory.appending(path: "missing")
            #expect(throws: PackageRequirements.LoadingError.invalidPackageRoot(missingRoot)) {
                try PackageRequirements.load(at: missingRoot)
            }
            
            try FileManager.default.createDirectory(
                at: temporaryDirectory.appending(path: "no-manifest"),
                withIntermediateDirectories: false
            )
            let noManifestRoot = temporaryDirectory.appending(path: "no-manifest")
            #expect(throws: PackageRequirements.LoadingError.invalidPackageRoot(noManifestRoot)) {
                try PackageRequirements.load(at: noManifestRoot)
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
            let requirements = try PackageRequirements.load(at: symlinkRoot)
            
            #expect(requirements.packageRoot == realRoot.resolvingSymlinksInPath().standardizedFileURL)
            #expect(requirements.toolsVersion == SwiftVersion(major: 6, minor: 2, patch: 0))
            #expect(requirements.swiftVersion == nil)
            #expect(requirements.swiftVersionFileURL == nil)
        }
    }
    
    @Test("Pre-six later directives require the first non-whitespace line")
    func preSixDirectivePlacement() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let manifestURL = temporaryDirectory.appending(path: "Package.swift")
            try write("// swift-tools-version: 5.9\n", to: manifestURL)
            let requirements = try PackageRequirements.load(at: temporaryDirectory)
            #expect(requirements.toolsVersion == SwiftVersion(major: 5, minor: 9, patch: 0))
            
            try write(
                "// a leading comment\n// swift-tools-version: 5.9\n",
                to: manifestURL
            )
            #expect(throws: PackageRequirements.LoadingError.toolsVersionMustBeFirstLine(
                SwiftVersion(major: 5, minor: 9, patch: 0)
            )) {
                try PackageRequirements.load(at: temporaryDirectory)
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
            let parentRequirements = try PackageRequirements.load(at: packageRoot)
            #expect(parentRequirements.swiftVersion == "6.1.2")
            #expect(parentRequirements.swiftVersionFileURL == parentVersionURL.standardizedFileURL)
            
            let packageVersionURL = packageRoot.appending(path: ".swift-version")
            try write(" 6.2.0\n", to: packageVersionURL)
            let packageRequirements = try PackageRequirements.load(at: packageRoot)
            #expect(packageRequirements.swiftVersion == "6.2.0")
            #expect(packageRequirements.swiftVersionFileURL == packageVersionURL.standardizedFileURL)
        }
    }
    
    @Test("Missing and malformed tools directives are rejected")
    func malformedToolsVersion() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let manifestURL = temporaryDirectory.appending(path: "Package.swift")
            try write("import PackageDescription\n", to: manifestURL)
            #expect(throws: PackageRequirements.LoadingError.malformedToolsVersion) {
                try PackageRequirements.load(at: temporaryDirectory)
            }
            
            try write("// swift-tools-version: 6\n", to: manifestURL)
            #expect(throws: PackageRequirements.LoadingError.malformedToolsVersion) {
                try PackageRequirements.load(at: temporaryDirectory)
            }
        }
    }
    
    @Test("A non-regular Swift version entry is rejected")
    func nonRegularSwiftVersionFile() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let manifestRoot = temporaryDirectory.appending(path: "package")
            try FileManager.default.createDirectory(at: manifestRoot, withIntermediateDirectories: false)
            try write("// swift-tools-version: 6.0\n", to: manifestRoot.appending(path: "Package.swift"))
            let versionDirectory = manifestRoot.appending(path: ".swift-version")
            try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: false)
            
            #expect(throws: PackageRequirements.LoadingError.unreadableSwiftVersionFile(
                versionDirectory.resolvingSymlinksInPath().standardizedFileURL
            )) {
                try PackageRequirements.load(at: manifestRoot)
            }
        }
    }
}

@Test("Swift version parsing rejects non-semantic selectors")
func strictSwiftVersionParsing() {
    #expect(SwiftVersion(parsing: "6.2") == SwiftVersion(major: 6, minor: 2, patch: 0))
    #expect(SwiftVersion(parsing: "6.2.1") == SwiftVersion(major: 6, minor: 2, patch: 1))
    
    for value in [
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
    ] {
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
