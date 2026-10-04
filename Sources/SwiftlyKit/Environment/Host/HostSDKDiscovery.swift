import Foundation

/// Discovers installed SDK contexts, with the active developer tools first.
struct HostSDKDiscovery: Sendable {

    private let runner: any SubprocessRunning

    init(runner: any SubprocessRunning = LiveSubprocessRunner()) {
        self.runner = runner
    }

    func active(in values: [String: String]) async throws -> HostSDK {

        let developerDirectory: URL
        if let path = values["DEVELOPER_DIR"] {
            developerDirectory = URL(filePath: path)
        } else {
            let result = try await runner.run(SubprocessCommand(
                executableURL: URL(filePath: "/usr/bin/xcode-select"),
                arguments: ["--print-path"],
                environment: values
            ))
            guard result.succeeded else { throw SwiftlyKitError.developerToolsUnavailable }
            developerDirectory = URL(filePath: result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let result = try await runner.run(SubprocessCommand(
            executableURL: URL(filePath: "/usr/bin/xcrun"),
            arguments: ["--sdk", "macosx", "--show-sdk-path"],
            environment: values
        ))
        guard result.succeeded else { throw SwiftlyKitError.developerToolsUnavailable }
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw SwiftlyKitError.developerToolsUnavailable }
        return try HostSDK(directory: URL(filePath: path), developerDirectory: developerDirectory)
    }

    /// Enumerates real installed SDKs. SDK versions order attempts; they never establish compatibility.
    func alternatives(to active: HostSDK) throws -> [HostSDK] {

        let manager = FileManager.default
        var developers = [active.developerDirectory, URL(filePath: "/Library/Developer/CommandLineTools")]
        let applications = [URL(filePath: "/Applications"), manager.homeDirectoryForCurrentUser.appending(path: "Applications")]
        for applicationsDirectory in applications {
            let apps = (try? manager.contentsOfDirectory(at: applicationsDirectory, includingPropertiesForKeys: nil)) ?? []
            for app in apps where app.pathExtension == "app" {
                let developer = app.appending(path: "Contents/Developer")
                if manager.fileExists(atPath: developer.appending(path: "Platforms/MacOSX.platform").path(percentEncoded: false)) {
                    developers.append(developer)
                }
            }
        }
        var seen = Set([active.directory.path(percentEncoded: false)])
        var contexts: [HostSDK] = []
        for developer in developers {
            let locations = [
                developer.appending(path: "SDKs"),
                developer.appending(path: "Platforms/MacOSX.platform/Developer/SDKs")
            ]
            for location in locations {
                let directories = (try? manager.contentsOfDirectory(at: location, includingPropertiesForKeys: nil)) ?? []
                for directory in directories where directory.pathExtension == "sdk" {
                    try Task.checkCancellation()
                    guard let sdk = try? HostSDK(directory: directory, developerDirectory: developer) else { continue }
                    guard seen.insert(sdk.directory.path(percentEncoded: false)).inserted else { continue }
                    contexts.append(sdk)
                }
            }
        }
        return contexts.sorted {
            let order = $0.version.compare($1.version, options: .numeric)
            if order != .orderedSame { return order == .orderedDescending }
            return $0.directory.path(percentEncoded: false) < $1.directory.path(percentEncoded: false)
        }
    }

}
