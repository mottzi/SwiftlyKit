import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Host preflight")
struct HostPreflightTests {

    @Test("Unsupported architecture short-circuits the SDK probe")
    func unsupportedArchitectureShortCircuitsProbe() async throws {

        let preflight = HostPreflight(
            hostFacts: HostFacts(
                isAppleSilicon: false,
                operatingSystemVersion: OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
            ),
            sdkProbe: { fatalError("SDK probe must not run on an unsupported architecture") }
        )

        await #expect(throws: SwiftlyKitError.unsupportedHost) {
            try await preflight.check()
        }
    }

    @Test("An old macOS version short-circuits the SDK probe")
    func oldOperatingSystemShortCircuitsProbe() async throws {

        let preflight = HostPreflight(
            hostFacts: HostFacts(
                isAppleSilicon: true,
                operatingSystemVersion: OperatingSystemVersion(majorVersion: 12, minorVersion: 6, patchVersion: 0)
            ),
            sdkProbe: { fatalError("SDK probe must not run on an unsupported macOS version") }
        )

        await #expect(throws: SwiftlyKitError.unsupportedHost) {
            try await preflight.check()
        }
    }

    @Test("Missing and invalid SDK paths map to developer tools unavailable")
    func invalidSDKPaths() async throws {

        let remotePreflight = HostPreflight(
            hostFacts: supportedHostFacts,
            sdkProbe: { URL(string: "https://example.com/MacOSX.sdk")! }
        )
        await #expect(throws: SwiftlyKitError.developerToolsUnavailable) {
            try await remotePreflight.check()
        }

        try await withTemporaryDirectory(prefix: "SwiftlyKit-HostPreflight") { temporaryDirectory in
            let missingURL = temporaryDirectory.appending(path: "missing-sdk")
            let missingPreflight = HostPreflight(
                hostFacts: supportedHostFacts,
                sdkProbe: { missingURL }
            )
            await #expect(throws: SwiftlyKitError.developerToolsUnavailable) {
                try await missingPreflight.check()
            }

            let fileURL = temporaryDirectory.appending(path: "sdk-file")
            try Data("not a directory".utf8).write(to: fileURL)
            let filePreflight = HostPreflight(
                hostFacts: supportedHostFacts,
                sdkProbe: { fileURL }
            )
            await #expect(throws: SwiftlyKitError.developerToolsUnavailable) {
                try await filePreflight.check()
            }
        }
    }

    @Test("A throwing SDK probe maps to developer tools unavailable")
    func throwingSDKProbe() async throws {

        let preflight = HostPreflight(
            hostFacts: supportedHostFacts,
            sdkProbe: { throw SwiftlyKitError.unsupportedHost }
        )

        await #expect(throws: SwiftlyKitError.developerToolsUnavailable) {
            try await preflight.check()
        }
    }

    @Test("A valid SDK symlink path succeeds")
    func validSDKPathSucceeds() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-HostPreflight") { temporaryDirectory in
            let realSDKURL = temporaryDirectory.appending(path: "MacOSX.sdk")
            try FileManager.default.createDirectory(at: realSDKURL, withIntermediateDirectories: false)
            let symlinkURL = temporaryDirectory.appending(path: "active-sdk")
            try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realSDKURL)

            let preflight = HostPreflight(
                hostFacts: supportedHostFacts,
                sdkProbe: { symlinkURL }
            )
            try await preflight.check()
        }
    }

    @Test("SDK probe cancellation remains CancellationError")
    func cancellationPreserved() async throws {

        let preflight = HostPreflight(
            hostFacts: supportedHostFacts,
            sdkProbe: { throw CancellationError() }
        )

        await #expect(throws: CancellationError.self) {
            try await preflight.check()
        }
    }

}

private let supportedHostFacts = HostFacts(
    isAppleSilicon: true,
    operatingSystemVersion: OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
)
