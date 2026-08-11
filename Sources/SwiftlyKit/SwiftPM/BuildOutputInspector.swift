import Foundation

enum BuildOutputInspector {

    static func runtimeResourceBundles(in directory: URL) throws -> [String] {

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )

        return try contents.compactMap { url in
            guard url.pathExtension == "resources" else { return nil }

            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  try isPrivacyMetadataBundle(url)
            else { return url.lastPathComponent }

            return nil
        }
        .sorted()
    }

    private static func isPrivacyMetadataBundle(_ directory: URL) throws -> Bool {

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )

        guard contents.count == 1,
              let privacyManifest = contents.first,
              privacyManifest.lastPathComponent == "PrivacyInfo.xcprivacy"
        else { return false }

        let values = try privacyManifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

}
