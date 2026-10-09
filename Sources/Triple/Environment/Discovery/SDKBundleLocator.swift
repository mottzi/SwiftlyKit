import Foundation

/// SDK bundle lookup within standard or caller-selected environment storage.
enum SDKBundleLocator {

    /// Returns the first installed bundle in the standard SwiftPM SDK locations.
    static func locate(identifier: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {

        let bundleName = "\(identifier).artifactbundle"
        
        let candidates = [
            homeDirectory.appending(path: ".swiftpm/swift-sdks/\(bundleName)"),
            homeDirectory.appending(path: "Library/org.swift.swiftpm/swift-sdks/\(bundleName)")
        ]

        for candidate in candidates {
            var isDirectory: ObjCBool = false

            let exists = FileManager.default.fileExists(
                atPath: candidate.path(percentEncoded: false),
                isDirectory: &isDirectory
            )
            guard exists else { continue }
            guard isDirectory.boolValue else { continue }

            return candidate.resolvingSymlinksInPath().standardizedFileURL
        }

        return nil
    }

    /// Returns the installed bundle in the selected storage without escaping a custom SDK directory.
    static func locate(
        identifier: String,
        in storage: EnvironmentStorage,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {

        switch storage {
            case .standard:
                return locate(identifier: identifier, homeDirectory: homeDirectory)
            case .directory:
                guard let location = try? storage.resolved(homeDirectory: homeDirectory),
                      let sdkDirectory = location.swiftPMSDKDirectory
                else { return nil }
                return locate(
                    identifier: identifier,
                    in: sdkDirectory,
                    confinedTo: sdkDirectory
                )
        }
    }

}

extension SDKBundleLocator {

    private static func locate(identifier: String, in directory: URL, confinedTo confinementDirectory: URL) -> URL? {

        let candidate = directory.appending(
            path: "\(identifier).artifactbundle",
            directoryHint: .isDirectory
        )
        var isDirectory: ObjCBool = false

        let exists = FileManager.default.fileExists(
            atPath: candidate.path(percentEncoded: false),
            isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else { return nil }

        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDirectory = confinementDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.pathComponents.starts(with: resolvedDirectory.pathComponents) else {
            return nil
        }
        return resolvedCandidate
    }

}
