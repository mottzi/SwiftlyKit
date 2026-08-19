import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Environment storage")
struct EnvironmentStorageTests {

    @Test("Removal plans preserve custom storage through Codable")
    func removalPlanStorageRoundTrip() throws {

        let storage = EnvironmentStorage.directory(
            try CanonicalFileURL.resolve(URL(filePath: "/tmp/swiftlykit-test-storage"))
        )
        let plan = EnvironmentRemovalPlan.toolchain(
            SwiftVersion(major: 6, minor: 3, patch: 3),
            in: storage
        )
        #expect(plan.environmentStorage == storage)

        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(EnvironmentRemovalPlan.self, from: data)

        #expect(decoded == plan)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(payload["schemaVersion"] as? Int == 2)
        #expect(payload["storage"] != nil)
    }

    @Test("Schema one removal plans decode into the standard storage namespace")
    func schemaOneRemovalPlanMigratesToStandardStorage() throws {

        let data = Data("""
        {"schemaVersion":1,"kind":"toolchain","toolchain":{"major":6,"minor":3,"patch":3},"sdkIdentifier":null}
        """.utf8)
        let decoded = try JSONDecoder().decode(EnvironmentRemovalPlan.self, from: data)
        let expected = EnvironmentRemovalPlan.toolchain(
            SwiftVersion(major: 6, minor: 3, patch: 3)
        )

        #expect(decoded == expected)
    }

    @Test("Removal plans reject an unsafe custom storage root during decoding")
    func removalPlanRejectsUnsafeStorageRoot() {

        let data = Data("""
        {
          "schemaVersion": 2,
          "kind": "toolchain",
          "toolchain": {"major": 6, "minor": 3, "patch": 3},
          "sdkIdentifier": null,
          "storage": {"kind": "directory", "directory": "/"}
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EnvironmentRemovalPlan.self, from: data)
        }
    }

    @Test("Standard storage derives its executable from the standard home")
    func standardStorageDerivesStandardBinDirectory() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-StandardStorage") { directory in
            let home = directory.appending(path: "home")
            let standardExecutable = home.appending(path: ".swiftly/bin/swiftly")
            try makeStorageTestExecutable(at: standardExecutable)

            let installation = try await SwiftlyInstallation.detect(
                storage: .standard,
                homeDirectory: home,
                versionProbe: { _ in "1.2.3" }
            )

            #expect(installation?.executableURL == standardExecutable.standardizedFileURL)
        }
    }

    @Test("Custom storage derives its bin directory and ignores ambient Swiftly paths")
    func customStorageDerivesBinDirectory() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-CustomStorage") { directory in
            let root = directory.appending(path: "swiftly")
            let customExecutable = root.appending(path: "bin/swiftly")
            try makeStorageTestExecutable(at: customExecutable)

            let installation = try await SwiftlyInstallation.detect(
                storage: .directory(root),
                homeDirectory: directory.appending(path: "unrelated-home"),
                versionProbe: { _ in "1.2.3" }
            )

            #expect(installation?.executableURL == customExecutable.standardizedFileURL)
        }
    }

    @Test("Storage resolution derives the standard and custom environment locations")
    func storageResolution() throws {

        let home = URL(filePath: "/tmp/swiftlykit-test-home")
        let standard = try EnvironmentStorage.standard.resolved(homeDirectory: home)
        #expect(storagePath(standard.homeDirectory) == storagePath(home.appending(path: ".swiftly")))
        #expect(storagePath(standard.binDirectory) == storagePath(home.appending(path: ".swiftly/bin")))
        #expect(storagePath(standard.toolchainsDirectory)
            == storagePath(home.appending(path: "Library/Developer/Toolchains")))
        #expect(standard.swiftPMSDKDirectory == nil)

        let customRoot = URL(filePath: "/tmp/swiftlykit-test-storage")
        let custom = try EnvironmentStorage.directory(customRoot).resolved(homeDirectory: home)
        #expect(storagePath(custom.homeDirectory) == storagePath(customRoot))
        #expect(storagePath(custom.binDirectory) == storagePath(customRoot.appending(path: "bin")))
        #expect(storagePath(custom.toolchainsDirectory)
            == storagePath(customRoot.appending(path: "toolchains")))
        #expect(storagePath(try #require(custom.swiftPMSDKDirectory))
            == storagePath(customRoot.appending(path: "swift-sdks")))
        let normalizedEnvironment = custom.environment.mapValues { storagePath(URL(filePath: $0)) }
        #expect(normalizedEnvironment == [
            "SWIFTLY_HOME_DIR": storagePath(customRoot),
            "SWIFTLY_BIN_DIR": storagePath(customRoot.appending(path: "bin")),
            "SWIFTLY_TOOLCHAINS_DIR": storagePath(customRoot.appending(path: "toolchains"))
        ])
    }

    @Test("Custom storage rejects the filesystem root and non-local paths")
    func storageValidationRejectsUnsafeRoots() {

        #expect(throws: SwiftlyKitError.unsafeEnvironmentStorage(URL(filePath: "/"))) {
            try EnvironmentStorage.directory(URL(filePath: "/")).resolved()
        }
        #expect(throws: SwiftlyKitError.self) {
            try EnvironmentStorage.directory(URL(string: "https://example.com/swiftly")!).resolved()
        }
    }

    @Test(
        "Custom storage rejects an existing regular file in its namespace",
        arguments: ["root", "bin", "toolchains", "swift-sdks"]
    )
    func storageRejectsExistingRegularFile(entry: String) throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-StorageFiles") { directory in
            let root = directory.appending(path: "environment")
            if entry == "root" {
                try Data("not a directory".utf8).write(to: root)
            } else {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("not a directory".utf8).write(to: root.appending(path: entry))
            }

            #expect(throws: SwiftlyKitError.unsafeEnvironmentStorage(root)) {
                try EnvironmentStorage.directory(root).resolved()
            }
        }
    }

    @Test("Removal plan round trips a noncanonical custom storage URL")
    func removalPlanPreservesNoncanonicalStorageURL() throws {

        let root = URL(filePath: "/tmp/swiftlykit-storage/a/../b")
        let plan = EnvironmentRemovalPlan.toolchain(
            SwiftVersion(major: 6, minor: 3, patch: 3),
            in: .directory(root)
        )
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(EnvironmentRemovalPlan.self, from: data)

        #expect(decoded == plan)
    }

    @Test("Custom storage rejects overlap with mutable workflow locations")
    func storageOverlapValidation() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-StorageOverlap") { directory in
            let root = directory.appending(path: "swiftly")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let storage = EnvironmentStorage.directory(root)

            #expect(throws: SwiftlyKitError.unsafeEnvironmentStorage(root)) {
                try storage.validateNotOverlapping(root.appending(path: "package"))
            }
            #expect(throws: SwiftlyKitError.unsafeEnvironmentStorage(root)) {
                try storage.validateNotOverlapping(root.deletingLastPathComponent())
            }
            try storage.validateNotOverlapping(directory.appending(path: "unrelated"))
        }
    }

    @Test(
        "Custom storage rejects derived directories that escape through symlinks before probing",
        arguments: ["bin", "toolchains", "swift-sdks"]
    )
    func storageRejectsEscapingDerivedDirectory(entry: String) async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-StorageSymlink") { directory in
            let root = directory.appending(path: "swiftly")
            let escaped = directory.appending(path: "escaped")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: escaped, withIntermediateDirectories: true)
            let derived = root.appending(path: entry)
            try FileManager.default.createSymbolicLink(at: derived, withDestinationURL: escaped)

            let storage = EnvironmentStorage.directory(root)
            await #expect(throws: SwiftlyKitError.self) {
                try await SwiftlyInstallation.detect(
                    storage: storage,
                    versionProbe: { _ in
                        Issue.record("An escaping environment storage symlink must fail before probing.")
                        return "1.2.3"
                    }
                )
            }
            let destination = try FileManager.default.destinationOfSymbolicLink(
                atPath: derived.path(percentEncoded: false)
            )
            #expect(destination == escaped.path(percentEncoded: false))
        }
    }

    @Test("Standard storage replaces ambient environment locations and preserves other process values")
    func standardStorageCommandEnvironment() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-StandardStorage") { directory in
            let home = directory.appending(path: "home")
            let executable = home.appending(path: ".swiftly/bin/swiftly")
            try makeStorageTestExecutable(at: executable)
            let installation = try #require(try await SwiftlyInstallation.detect(
                storage: .standard,
                homeDirectory: home,
                versionProbe: { _ in "1.2.3" }
            ))

            let command = installation.command(
                tool: "swift",
                toolchain: SwiftVersion(major: 6, minor: 3, patch: 3),
                arguments: ["--version"],
                environment: [
                    "PATH": "/trusted/path",
                    "SWIFTLY_HOME_DIR": "/ambient/home",
                    "SWIFTLY_BIN_DIR": "/ambient/bin",
                    "SWIFTLY_TOOLCHAINS_DIR": "/ambient/toolchains"
                ]
            )

            #expect(command.environment?["PATH"] == "/trusted/path")
            #expect(storagePath(URL(filePath: command.environment?["SWIFTLY_HOME_DIR"] ?? ""))
                == storagePath(home.appending(path: ".swiftly")))
            #expect(storagePath(URL(filePath: command.environment?["SWIFTLY_BIN_DIR"] ?? ""))
                == storagePath(home.appending(path: ".swiftly/bin")))
            #expect(storagePath(URL(filePath: command.environment?["SWIFTLY_TOOLCHAINS_DIR"] ?? ""))
                == storagePath(home.appending(path: "Library/Developer/Toolchains")))
        }
    }

    @Test("Custom version probing receives only the derived environment namespace")
    func customVersionProbeEnvironment() async throws {

        try await withTemporaryDirectory(prefix: "SwiftlyKit-CustomStorage") { directory in
            let root = directory.appending(path: "swiftly")
            let executable = root.appending(path: "bin/swiftly")
            let marker = directory.appending(path: "probe-environment")
            let script = """
            #!/bin/sh
            printf '%s|%s|%s' "$SWIFTLY_HOME_DIR" "$SWIFTLY_BIN_DIR" "$SWIFTLY_TOOLCHAINS_DIR" \
                > "\(marker.path(percentEncoded: false))"
            printf '1.2.3\\n'
            """
            try makeStorageTestExecutable(at: executable, contents: script)

            _ = try await SwiftlyInstallation.detect(
                storage: .directory(root),
                versionProbe: nil
            )

            let environment = try String(contentsOf: marker, encoding: .utf8)
            let normalizedEnvironment = environment
                .split(separator: "|")
                .map { storagePath(URL(filePath: String($0))) }
            #expect(normalizedEnvironment == [
                storagePath(root),
                storagePath(root.appending(path: "bin")),
                storagePath(root.appending(path: "toolchains"))
            ])
        }
    }

}

private func storagePath(_ url: URL) -> String {

    let path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    let normalized = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    guard normalized != "/" else { return normalized }
    return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
}

private func makeStorageTestExecutable(at url: URL, contents: String = "#!/bin/sh\nexit 0\n") throws {

    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path(percentEncoded: false)
    )
}
