import Foundation
import CryptoKit

/// One installed developer-tools context used for host manifests, plugins, and macros.
struct HostSDK: Sendable, Equatable {

    let directory: URL
    let developerDirectory: URL
    let version: String
    private let fingerprint: String

    init(directory: URL, developerDirectory: URL) throws {

        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        let developerDirectory = developerDirectory.resolvingSymlinksInPath().standardizedFileURL
        let metadata = try Self.metadata(at: directory)
        guard FileManager.default.isReadableFile(atPath: developerDirectory.path(percentEncoded: false))
        else { throw SwiftlyKitError.developerToolsUnavailable }
        self.directory = directory
        self.developerDirectory = developerDirectory
        self.version = metadata.version
        self.fingerprint = metadata.fingerprint
    }

    /// Rejects removed or replaced SDKs instead of falling back to the machine's active SDK.
    func validate() throws {

        guard let current = try? Self(directory: directory, developerDirectory: developerDirectory), current == self
        else {
            throw SwiftlyKitError.packageInspectionFailed(
                "The prepared macOS SDK at \(directory.path(percentEncoded: false)) changed or is unavailable. "
                    + "Inspect the package again before building."
            )
        }
    }

    /// Binds child processes without changing the user's global developer-tools selection.
    func applying(to values: [String: String]) -> [String: String] {
        var values = values
        values["SDKROOT"] = directory.path(percentEncoded: false)
        values["DEVELOPER_DIR"] = developerDirectory.path(percentEncoded: false)
        return values
    }

}

extension HostSDK {

    private static func metadata(at directory: URL) throws -> (version: String, fingerprint: String) {

        let json = directory.appending(path: "SDKSettings.json")
        let plist = directory.appending(path: "SDKSettings.plist")
        let data: Data
        let settings: Settings
        if FileManager.default.fileExists(atPath: json.path(percentEncoded: false)) {
            data = try Data(contentsOf: json)
            settings = try JSONDecoder().decode(Settings.self, from: data)
        } else {
            data = try Data(contentsOf: plist)
            settings = try PropertyListDecoder().decode(Settings.self, from: data)
        }
        guard !settings.version.isEmpty else { throw SwiftlyKitError.developerToolsUnavailable }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path(percentEncoded: false))
        let identity = String(describing: attributes[.systemFileNumber]) + String(describing: attributes[.modificationDate])
        let fingerprint = SHA256.hash(data: data + Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return (settings.version, fingerprint)
    }

}

extension HostSDK {

    private struct Settings: Decodable {
        let version: String

        private enum CodingKeys: String, CodingKey {
            case version = "Version"
        }
    }

}
