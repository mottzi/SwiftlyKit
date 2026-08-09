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

            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else { continue }

            return candidate.resolvingSymlinksInPath().standardizedFileURL
        }

        return nil
    }

}
