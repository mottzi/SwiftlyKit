import Foundation
import Testing
@testable import SwiftlyKit

@Suite("SwiftPM environment validation")
struct SwiftPMValidationTests {

    @Test("A compatible package, Swiftly executable, and exact SDK validate")
    func acceptsExactEnvironment() throws {

        try withSwiftPMTemporaryDirectory { directory in
            let environment = try validationEnvironment(in: directory, toolsVersion: "6.0")

            try SwiftPM.validate(environment, locateSDK: { identifier in
                #expect(identifier == environment.staticLinuxSDK.identifier)
                return environment.sdkBundleURL
            })
        }
    }

    @Test("Validation rejects incompatible package inputs, Swiftly, and SDK state")
    func rejectsInvalidEnvironmentState() throws {

        try withSwiftPMTemporaryDirectory { directory in
            let incompatiblePackage = try validationEnvironment(in: directory, toolsVersion: "6.3")
            #expect(throws: SwiftlyKitError.unsupportedToolsVersion(
                SwiftVersion(major: 6, minor: 3, patch: 0)
            )) {
                try SwiftPM.validate(incompatiblePackage, locateSDK: { _ in incompatiblePackage.sdkBundleURL })
            }

            try Data("// swift-tools-version: 6.0\n".utf8).write(
                to: directory.appending(path: "Package.swift")
            )
            let valid = try validationEnvironment(in: directory, toolsVersion: "6.0")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: valid.swiftlyExecutableURL.path
            )
            #expect(throws: SwiftlyKitError.incompatibleSwiftly) {
                try SwiftPM.validate(valid, locateSDK: { _ in valid.sdkBundleURL })
            }

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: valid.swiftlyExecutableURL.path
            )
            #expect(throws: SwiftlyKitError.staticLinuxSDKUnavailable) {
                try SwiftPM.validate(valid, locateSDK: { _ in directory.appending(path: "another-sdk") })
            }
        }
    }

}

private func validationEnvironment(
    in directory: URL,
    toolsVersion: String
) throws -> LocalBuildEnvironment {

    try Data("// swift-tools-version: \(toolsVersion)\n".utf8).write(
        to: directory.appending(path: "Package.swift")
    )
    let swiftly = directory.appending(path: "swiftly")
    if !FileManager.default.fileExists(atPath: swiftly.path) {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: swiftly)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swiftly.path)

    return LocalBuildEnvironment(
        swiftVersion: SwiftVersion(major: 6, minor: 2, patch: 1),
        staticLinuxSDK: StaticLinuxSDK(identifier: "sdk", version: "1.0.0"),
        packageRoot: directory,
        swiftlyExecutableURL: swiftly,
        sdkBundleURL: directory.appending(path: "sdk.artifactbundle"),
        target: .linux(.arm64)
    )
}
