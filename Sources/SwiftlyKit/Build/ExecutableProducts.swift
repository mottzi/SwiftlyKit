// MARK: - ExecutableProduct

/// An executable product discovered from SwiftPM package metadata.
public struct ExecutableProduct: Sendable, Hashable {

    /// The product name reported by SwiftPM and passed to `swift build --product`.
    public let name: String

}

// MARK: - ExecutableProducts

/// Executable products discovered from one prepared package in name order.
public struct ExecutableProducts: Sendable {

    private let products: [ExecutableProduct]

    init(_ products: [ExecutableProduct]) {
        self.products = products
    }

    /// Selects the named product, or the sole product if `name` is `nil`.
    /// Throws if the named product is absent or sole-product selection is not possible.
    public func select(_ name: String? = nil) throws(SwiftlyKitError) -> ExecutableProduct {

        if let name {
            let namedProduct = products.first { $0.name == name }
            guard let namedProduct else { throw SwiftlyKitError.executableProductNotFound(name) }
            return namedProduct
        }

        guard products.count == 1, let product = products.first
        else { throw SwiftlyKitError.executableProductSelectionRequired(products.map(\.name)) }

        return product
    }

}

// MARK: - RandomAccessCollection

extension ExecutableProducts: RandomAccessCollection {

    /// The product stored at each collection position.
    public typealias Element = ExecutableProduct

    /// The integer position of a product.
    public typealias Index = Int

    /// The position of the first product.
    public var startIndex: Index {
        products.startIndex
    }

    /// The position after the last product.
    public var endIndex: Index {
        products.endIndex
    }

    /// Returns the position after the specified position.
    public func index(after index: Index) -> Index {
        products.index(after: index)
    }

    /// Returns the position before the specified position.
    public func index(before index: Index) -> Index {
        products.index(before: index)
    }

    /// Returns the product at the specified position.
    public subscript(position: Index) -> Element {
        products[position]
    }

}
