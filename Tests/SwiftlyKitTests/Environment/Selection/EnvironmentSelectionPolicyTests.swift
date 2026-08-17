import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Environment selection policy")
struct EnvironmentSelectionPolicyTests {

    @Test("Automatic selection follows preference, installed pair, then newest official precedence")
    func automaticPrecedence() throws {

        let releases = [selectionRelease("6.2.4"), selectionRelease("6.3.3")]
        let inventory = InstalledEnvironmentInventory(
            toolchains: [selectionVersion("6.2.4")],
            sdks: [InstalledStaticLinuxSDK(
                toolchainVersion: selectionVersion("6.2.4"),
                identifier: releases[0].staticLinuxSDK.identifier
            )]
        )

        let preferred = try select(
            preference: "6.3.3",
            releases: releases,
            inventory: inventory
        )
        let installed = try select(
            preference: nil,
            releases: releases,
            inventory: inventory
        )
        let newest = try select(preference: nil, releases: releases)

        #expect(preferred == releases[1])
        #expect(installed == releases[0])
        #expect(newest == releases[1])
    }

    @Test("Installed toolchain and SDK must form the exact official pair")
    func requiresExactInstalledPair() throws {

        let older = selectionRelease("6.2.4")
        let newer = selectionRelease("6.3.3")
        let selection = try select(
            preference: nil,
            releases: [older, newer],
            inventory: InstalledEnvironmentInventory(
                toolchains: [older.version],
                sdks: [InstalledStaticLinuxSDK(
                    toolchainVersion: newer.version,
                    identifier: older.staticLinuxSDK.identifier
                )]
            )
        )

        #expect(selection == newer)
    }

    @Test("Selection canonicalizes unordered duplicate releases before applying precedence")
    func canonicalizesReleases() throws {

        let older = selectionRelease("6.2.4")
        let superseded = selectionRelease("6.3.3", architectures: [.x86_64])
        let newest = selectionRelease("6.3.3", architectures: [.arm64])

        let selection = try select(
            preference: nil,
            releases: [older, superseded, newest]
        )

        #expect(selection == newest)
    }

    @Test("Exact selection enforces tools version and architecture")
    func validatesExactSelection() {

        let release = selectionRelease("6.2.4", architectures: [.x86_64])

        #expect(throws: EnvironmentSelectionPolicy.SelectionError.incompatibleToolsVersion(
            requested: selectionVersion("6.2.4"),
            required: selectionVersion("6.3")
        )) {
            try EnvironmentSelectionPolicy.select(
                toolchain: .exact(selectionVersion("6.2.4")),
                toolsVersion: selectionVersion("6.3"),
                swiftVersionPreference: nil,
                architecture: .x86_64,
                releases: [release],
                inventory: InstalledEnvironmentInventory(toolchains: [], sdks: [])
            )
        }

        #expect(throws: EnvironmentSelectionPolicy.SelectionError.unsupportedArchitecture(
            version: selectionVersion("6.2.4"),
            architecture: .arm64
        )) {
            try EnvironmentSelectionPolicy.select(
                toolchain: .exact(selectionVersion("6.2.4")),
                toolsVersion: selectionVersion("6.2"),
                swiftVersionPreference: nil,
                architecture: .arm64,
                releases: [release],
                inventory: InstalledEnvironmentInventory(toolchains: [], sdks: [])
            )
        }
    }

    @Test("Automatic preference rejects snapshots and unavailable stable releases")
    func rejectsInvalidPreferences() {

        #expect(throws: EnvironmentSelectionPolicy.SelectionError.invalidSwiftVersionPreference("main-snapshot")) {
            try select(preference: "main-snapshot", releases: [selectionRelease("6.3.3")])
        }
        #expect(throws: EnvironmentSelectionPolicy.SelectionError.unavailableRelease(selectionVersion("6.2.4"))) {
            try select(preference: "6.2.4", releases: [selectionRelease("6.3.3")])
        }
    }

    private func select(
        preference: String?,
        releases: [OfficialStableRelease],
        inventory: InstalledEnvironmentInventory = InstalledEnvironmentInventory(toolchains: [], sdks: [])
    ) throws -> OfficialStableRelease {

        try EnvironmentSelectionPolicy.select(
            toolchain: .automatic,
            toolsVersion: selectionVersion("6.2"),
            swiftVersionPreference: preference,
            architecture: .arm64,
            releases: releases,
            inventory: inventory
        )
    }

}

private func selectionRelease(
    _ version: String,
    architectures: Set<LinuxArchitecture> = [.arm64, .x86_64]
) -> OfficialStableRelease {

    let parsedVersion = selectionVersion(version)
    let identifier = "swift-\(version)-RELEASE_static-linux-0.1.0"
    return OfficialStableRelease(
        version: parsedVersion,
        staticLinuxSDK: StaticLinuxSDK(
            identifier: identifier,
            version: "0.1.0"
        ),
        staticLinuxSDKMetadata: StaticLinuxSDKMetadata(
            downloadURL: URL(string: "https://download.swift.org/\(identifier).tar.gz")!,
            checksum: String(repeating: "a", count: 64),
            supportedArchitectures: architectures
        )!
    )
}

private func selectionVersion(_ value: String) -> SwiftVersion {
    SwiftVersion(value)!
}
