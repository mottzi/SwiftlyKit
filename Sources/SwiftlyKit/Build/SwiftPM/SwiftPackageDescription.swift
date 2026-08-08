import Foundation

struct SwiftPackageDescription: Sendable {
    
    let products: [ExecutableProduct]
    
    init(data: Data) throws {
        
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwiftPMError.malformedPackageDescription
        }
        let rawTargets = root["targets"] as? [[String: Any]] ?? []
        let targetNames = Set(rawTargets.compactMap { $0["name"] as? String })
        let targets = Dictionary(uniqueKeysWithValues: rawTargets.compactMap { raw -> (String, Target)? in
            guard let name = raw["name"] as? String, let type = raw["type"] as? String else { return nil }
            return (name, Target(
                type: type,
                dependencies: Self.referencedTargetNames(in: raw["dependencies"], knownNames: targetNames),
                hasResources: !((raw["resources"] as? [Any]) ?? []).isEmpty
            ))
        })

        let explicitProducts: [(name: String, targets: [String])] =
            (root["products"] as? [[String: Any]] ?? []).compactMap { raw in
                guard let type = raw["type"] as? [String: Any], type.keys.contains("executable"),
                      let name = raw["name"] as? String
                else { return nil }
                return (name, raw["targets"] as? [String] ?? [])
            }
        let coveredTargets = Set(explicitProducts.flatMap(\.targets))
        let implicitProducts = targets.compactMap { name, target -> (name: String, targets: [String])? in
            guard target.type == "executable", !coveredTargets.contains(name) else { return nil }
            return (name, [name])
        }
        let allProducts = explicitProducts + implicitProducts
        products = allProducts.map { ExecutableProduct(name: $0.name) }.sorted { $0.name < $1.name }
        resourceProducts = Set(allProducts.compactMap { product in
            Self.requiresResources(product.targets, targets: targets) ? product.name : nil
        })
    }
    
    func requiresResources(_ productName: String) -> Bool {
        resourceProducts.contains(productName)
    }
    
    private static func referencedTargetNames(in value: Any?, knownNames: Set<String>) -> Set<String> {
        
        guard let value else { return [] }
        if let string = value as? String { return knownNames.contains(string) ? [string] : [] }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { $0.formUnion(referencedTargetNames(in: $1, knownNames: knownNames)) }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set<String>()) {
                $0.formUnion(referencedTargetNames(in: $1.value, knownNames: knownNames))
            }
        }
        return []
    }
    
    private static func requiresResources(_ roots: [String], targets: [String: Target]) -> Bool {
        
        var pending = roots
        var visited: Set<String> = []
        while let name = pending.popLast() {
            guard visited.insert(name).inserted, let target = targets[name] else { continue }
            if target.hasResources { return true }
            pending.append(contentsOf: target.dependencies)
        }
        return false
    }
    
    private struct Target {
        
        let type: String
        let dependencies: Set<String>
        let hasResources: Bool
        
    }

    private let resourceProducts: Set<String>
    
}
