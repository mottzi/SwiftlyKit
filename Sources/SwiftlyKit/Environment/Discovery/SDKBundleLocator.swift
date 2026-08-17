import Foundation

enum SDKBundleLocator {

    static func locate(identifier: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {

        let bundleName = "\(identifier).artifactbundle"
        
        let candidates = [
            homeDirectory.appending(path: ".swiftpm/swift-sdks/\(bundleName)"),
            homeDirectory.appending(path: "Library/org.swift.swiftpm/swift-sdks/\(bundleName)")
        ]

        for candidate in candidates {
            var isDirectory: ObjCBool = false

            guard FileManager.default.fileExists(
                atPath: candidate.path(percentEncoded: false),
                isDirectory: &isDirectory
            ) else { continue }
            guard isDirectory.boolValue else { continue }

            return candidate.resolvingSymlinksInPath().standardizedFileURL
        }

        return nil
    }

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

    private static func locate(
        identifier: String,
        in directory: URL,
        confinedTo confinementDirectory: URL
    ) -> URL? {

        let candidate = directory.appending(
            path: "\(identifier).artifactbundle",
            directoryHint: .isDirectory
        )
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(
            atPath: candidate.path(percentEncoded: false),
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }

        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDirectory = confinementDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.pathComponents.starts(with: resolvedDirectory.pathComponents) else {
            return nil
        }
        return resolvedCandidate
    }

}
