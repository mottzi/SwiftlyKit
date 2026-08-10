import Foundation

func packageDescriptionJSON(executableProducts productNames: [String]) throws -> String {

    let products: [[String: Any]] = productNames.map { name in
        [
            "name": name,
            "targets": [name],
            "type": ["executable": NSNull()]
        ]
    }
    let targets: [[String: Any]] = productNames.map { name in
        [
            "name": name,
            "type": "executable",
            "dependencies": [],
            "resources": []
        ]
    }
    let data = try JSONSerialization.data(
        withJSONObject: ["products": products, "targets": targets],
        options: [.sortedKeys]
    )
    return String(decoding: data, as: UTF8.self)
}
