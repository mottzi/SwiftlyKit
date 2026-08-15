import Foundation

struct PackageDescription {

    let products: [ExecutableProduct]

    init(data: Data) throws {

        do {
            let description = try JSONDecoder().decode(Description.self, from: data)
            products = try Self.products(from: description)
        } catch {
            throw SwiftPMError.malformedPackageDescription
        }
    }

}

extension PackageDescription {

    private static func products(from description: Description) throws -> [ExecutableProduct] {

        var targetNames: Set<String> = []
        for target in description.targets {
            try validate(identifier: target.name)
            guard targetNames.insert(target.name).inserted else { throw DescriptionError.duplicateIdentifier }
        }

        let targets = Dictionary(uniqueKeysWithValues: description.targets.map { ($0.name, $0.kind) })

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

            guard product.kind == .executable else { continue }
            explicitProducts.append((product.name, product.targets))
        }

        let coveredTargets = Set(explicitProducts.flatMap(\.targets))
        let implicitProducts = targets.compactMap { name, kind -> (name: String, targets: [String])? in
            guard kind == .executable else { return nil }
            guard !coveredTargets.contains(name) else { return nil }
            guard !productNames.contains(name) else { return nil }

            return (name, [name])
        }

        let allProducts = explicitProducts + implicitProducts
        return allProducts.map { ExecutableProduct(name: $0.name) }.sorted { $0.name < $1.name }
    }

    private static func validate(identifier: String) throws {
        guard !identifier.isEmpty else { throw DescriptionError.emptyIdentifier }
    }

}

extension PackageDescription {

    private enum DescriptionError: Error {

        case duplicateIdentifier
        case emptyIdentifier
        case missingTarget

    }

}
