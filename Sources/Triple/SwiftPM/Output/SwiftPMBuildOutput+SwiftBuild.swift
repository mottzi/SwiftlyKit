import Foundation

extension SwiftPMBuildOutput {

    /// Reads only the selected product's linked resource targets from the current Swift Build project model.
    static func swiftBuildBundleNames(
        product: String,
        configuration: BuildConfiguration,
        scratchDirectory: URL
    ) throws -> Set<String> {

        let manifest = scratchDirectory.appending(path: "manifest.pif")
        try RuntimeResourceTreeValidator.validateRegularFile(manifest, containedIn: scratchDirectory)
        let objects: [SwiftBuildPIFObject]
        do {
            objects = try JSONDecoder().decode([SwiftBuildPIFObject].self, from: Data(contentsOf: manifest))
        } catch {
            throw SwiftPMError.runtimeResourceVerificationFailed
        }

        let configurationName = configuration == .release ? "Release" : "Debug"
        var targets: [String: SwiftBuildPIFTarget] = [:]
        for target in objects.compactMap(\.target) {
            guard targets.updateValue(target, forKey: target.guid) == nil
            else { throw SwiftPMError.runtimeResourceVerificationFailed }
        }
        let products = targets.values.filter { target in
            target.productTypeIdentifier == "com.apple.product-type.tool"
                && target.buildConfigurations.contains {
                    $0.name == configurationName && $0.buildSettings.targetName == product
                }
        }
        guard products.count == 1, let selected = products.first
        else { throw SwiftPMError.runtimeResourceVerificationFailed }

        var pending = [selected.guid]
        var visited = Set<String>()
        var bundles = Set<String>()
        while let guid = pending.popLast() {
            guard visited.insert(guid).inserted else { continue }
            guard let target = targets[guid], ["standard", "packageProduct"].contains(target.type)
            else { throw SwiftPMError.runtimeResourceVerificationFailed }
            let configurations = target.buildConfigurations.filter { $0.name == configurationName }
            guard configurations.count == 1, let settings = configurations.first?.buildSettings
            else { throw SwiftPMError.runtimeResourceVerificationFailed }

            if let name = settings.resourceBundleName {
                guard !name.isEmpty, URL(filePath: name).lastPathComponent == name,
                      !name.contains("$("), bundles.insert(name + ".bundle").inserted
                else { throw SwiftPMError.runtimeResourceVerificationFailed }
            }

            let phases = (target.buildPhases ?? []) + [target.frameworksBuildPhase].compactMap { $0 }
            for phase in phases where phase.type == "com.apple.buildphase.frameworks" {
                for file in phase.buildFiles {
                    // The frameworks phase contains linked edges. General dependencies also include host tools.
                    guard file.platformFilters.isEmpty || file.platformFilters.contains(where: {
                        $0.platform == "linux" && ($0.environment ?? "") == "musl"
                    }) else { continue }
                    if let dependency = file.targetReference {
                        pending.append(dependency)
                    } else if file.fileReference == nil {
                        throw SwiftPMError.runtimeResourceVerificationFailed
                    }
                }
            }
        }
        return bundles
    }

}

// Decode only the PIF fields needed for resource selection. PIF remains an internal SwiftPM format.
private struct SwiftBuildPIFObject: Decodable {

    let target: SwiftBuildPIFTarget?

    private enum CodingKeys: String, CodingKey { case type, contents }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        target = try values.decode(String.self, forKey: .type) == "target"
            ? values.decode(SwiftBuildPIFTarget.self, forKey: .contents) : nil
    }

}

private struct SwiftBuildPIFTarget: Decodable {

    let guid: String
    let type: String
    let productTypeIdentifier: String?
    let buildConfigurations: [Configuration]
    let buildPhases: [BuildPhase]?
    let frameworksBuildPhase: BuildPhase?

    struct Configuration: Decodable {
        let name: String
        let buildSettings: Settings
    }

    struct Settings: Decodable {
        let targetName: String?
        let resourceBundleName: String?

        enum CodingKeys: String, CodingKey {
            case targetName = "TARGET_NAME"
            case resourceBundleName = "PACKAGE_RESOURCE_BUNDLE_NAME"
        }
    }

    struct BuildPhase: Decodable {
        let type: String
        let buildFiles: [BuildFile]
    }

    struct BuildFile: Decodable {
        let targetReference: String?
        let fileReference: String?
        let platformFilters: [PlatformFilter]
    }

    struct PlatformFilter: Decodable {
        let platform: String
        let environment: String?
    }

}
