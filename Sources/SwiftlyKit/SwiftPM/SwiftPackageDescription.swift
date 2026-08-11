import Foundation

struct SwiftPackageDescription {

    let products: [ExecutableProduct]
    private let resourceProducts: Set<String>

    init(data: Data) throws {

        do {
            let description = try JSONDecoder().decode(Description.self, from: data)
            let package = try Self.package(from: description)

            products = package.products
            resourceProducts = package.resourceProducts
        } catch {
            throw SwiftPMError.malformedPackageDescription
        }
    }

    func requiresRuntimeResources(_ productName: String) -> Bool {
        resourceProducts.contains(productName)
    }

}

extension SwiftPackageDescription {

    private static func package(from description: Description) throws -> Package {

        var targetNames: Set<String> = []
        for target in description.targets {
            try validate(identifier: target.name)
            guard targetNames.insert(target.name).inserted else { throw DescriptionError.duplicateIdentifier }
        }

        var targets: [String: Target] = [:]
        for target in description.targets {
            targets[target.name] = Target(
                kind: target.type,
                dependencies: target.dependencies,
                resourceRequirement: resourceRequirement(for: target.resources)
            )
        }

        for target in targets.values {
            for dependency in target.dependencies {
                guard case .target(let name) = dependency else { continue }
                guard targets[name] != nil else { throw DescriptionError.missingTarget }
            }
        }

        var productNames: Set<String> = []
        var explicitProducts: [(name: String, targets: [String])] = []

        for product in description.products {
            try validate(identifier: product.name)
            guard productNames.insert(product.name).inserted else { throw DescriptionError.duplicateIdentifier }
            guard !product.targets.isEmpty else { throw DescriptionError.missingTarget }

            var referencedTargets: Set<String> = []
            for target in product.targets {
                try validate(identifier: target)
                guard referencedTargets.insert(target).inserted else { throw DescriptionError.duplicateIdentifier }
                guard targets[target] != nil else { throw DescriptionError.missingTarget }
            }

            guard product.type == .executable else { continue }
            explicitProducts.append((product.name, product.targets))
        }

        let coveredTargets = Set(explicitProducts.flatMap(\.targets))
        let implicitProducts = targets.compactMap { name, target -> (name: String, targets: [String])? in
            guard target.kind == .executable else { return nil }
            guard !coveredTargets.contains(name) else { return nil }
            guard !productNames.contains(name) else { return nil }

            return (name, [name])
        }

        let allProducts = explicitProducts + implicitProducts
        let products = allProducts.map { ExecutableProduct(name: $0.name) }.sorted { $0.name < $1.name }
        let resourceProducts = Set(allProducts.compactMap { product -> String? in
            switch resourceRequirement(for: product.targets, targets: targets) {
                case .none: nil
                case .required, .unknown: product.name
            }
        })

        return Package(products: products, resourceProducts: resourceProducts)
    }

    private static func validate(identifier: String) throws {
        guard !identifier.isEmpty else { throw DescriptionError.emptyIdentifier }
    }

    private static func resourceRequirement(
        for roots: [String],
        targets: [String: Target]
    ) -> ResourceRequirement {

        var pending = roots
        var visited: Set<String> = []
        var result = ResourceRequirement.none

        while let name = pending.popLast() {
            guard visited.insert(name).inserted else { continue }
            guard let target = targets[name] else {
                result = .unknown
                continue
            }

            switch target.resourceRequirement {
                case .none: break
                case .required: return .required
                case .unknown: result = .unknown
            }

            for dependency in target.dependencies {
                switch dependency {
                    case .target(let name):
                        pending.append(name)

                    case .byName(let name):
                        if targets[name] != nil { pending.append(name) }

                    case .product:
                        break

                    case .unknown:
                        result = .unknown
                }
            }
        }

        return result
    }

    private static func resourceRequirement(for resources: [Description.Resource]) -> ResourceRequirement {

        var result = ResourceRequirement.none

        for resource in resources {
            switch resource.rule {
                case .embedInCode: break
                case .copy, .process: return .required
                case .unknown: result = .unknown
            }
        }

        return result
    }

}

extension SwiftPackageDescription {

    private struct Package {

        let products: [ExecutableProduct]
        let resourceProducts: Set<String>

    }

    private struct Target {

        let kind: Description.TargetKind
        let dependencies: [Description.Dependency]
        let resourceRequirement: ResourceRequirement

    }

    private enum ResourceRequirement {

        case none
        case required
        case unknown

    }

    private enum DescriptionError: Error {

        case duplicateIdentifier
        case emptyIdentifier
        case missingTarget

    }

}
