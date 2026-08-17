import Foundation
import Testing
@testable import SwiftlyKit

@Suite("SDK bundle locator")
struct SDKBundleLocatorTests {

    @Test("Locates canonical SDK directories in both official SwiftPM locations")
    func officialLocations() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SDKLocator") { home in
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

    @Test("Locates a custom SDK registry only below its environment storage root")
    func customEnvironmentStorageLocation() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SDKLocator") { directory in
            let identifier = "swift-6.3.3-RELEASE_static-linux-0.1.0"
            let storageRoot = directory.appending(path: "environment")
            let customBundle = storageRoot.appending(
                path: "swift-sdks/\(identifier).artifactbundle"
            )
            try FileManager.default.createDirectory(at: customBundle, withIntermediateDirectories: true)

            #expect(
                SDKBundleLocator.locate(
                    identifier: identifier,
                    in: .directory(storageRoot),
                    homeDirectory: directory.appending(path: "unrelated-home")
                ) == customBundle.standardizedFileURL
            )
            #expect(
                SDKBundleLocator.locate(
                    identifier: identifier,
                    homeDirectory: directory.appending(path: "unrelated-home")
                ) == nil
            )
        }
    }

    @Test("A custom SDK bundle symlink cannot escape its registry")
    func customSDKBundleSymlinkEscapeIsRejected() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SDKLocator") { directory in
            let identifier = "swift-6.3.3-RELEASE_static-linux-0.1.0"
            let storageRoot = directory.appending(path: "environment")
            let sdkDirectory = storageRoot.appending(path: "swift-sdks")
            let outsideBundle = directory.appending(path: "outside.artifactbundle")
            let customBundle = sdkDirectory.appending(path: "\(identifier).artifactbundle")
            try FileManager.default.createDirectory(at: sdkDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outsideBundle, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: customBundle, withDestinationURL: outsideBundle)

            #expect(
                SDKBundleLocator.locate(
                    identifier: identifier,
                    in: .directory(storageRoot),
                    homeDirectory: directory.appending(path: "unrelated-home")
                ) == nil
            )
        }
    }

}
