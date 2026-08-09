import Foundation
import Testing
@testable import SwiftlyKit

@Suite("SDK bundle locator")
struct SDKBundleLocatorTests {

    @Test("Locates canonical SDK directories in both official SwiftPM locations")
    func officialLocations() throws {

        try withSDKLocatorTemporaryDirectory { home in
            let identifier = "swift-6.3.3-RELEASE_static-linux-0.1.0"
            let bundleName = "\(identifier).artifactbundle"
            let modernParent = home.appending(path: "Library/org.swift.swiftpm/swift-sdks")
            let modernBundle = modernParent.appending(path: bundleName)
            try FileManager.default.createDirectory(at: modernBundle, withIntermediateDirectories: true)

            #expect(SDKBundleLocator.locate(identifier: identifier, homeDirectory: home) ==
                modernBundle.standardizedFileURL)

            let legacyParent = home.appending(path: ".swiftpm/swift-sdks")
            let realBundle = home.appending(path: "real-sdk")
            let legacyBundle = legacyParent.appending(path: bundleName)
            try FileManager.default.createDirectory(at: realBundle, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: legacyParent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: legacyBundle, withDestinationURL: realBundle)

            #expect(SDKBundleLocator.locate(identifier: identifier, homeDirectory: home) ==
                realBundle.resolvingSymlinksInPath().standardizedFileURL)
        }
    }

}

private func withSDKLocatorTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SwiftlyKit-SDKLocator-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}
