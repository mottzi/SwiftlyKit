import Foundation
import ResourceDependency

print(resourceMessage())
let rootMessage = Bundle.module.url(forResource: "root-message", withExtension: "txt")!
print(try String(contentsOf: rootMessage, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
