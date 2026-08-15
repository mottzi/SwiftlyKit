import Foundation

/// Returns the packaged acceptance-test message.
public func resourceMessage() -> String {
    let url = Bundle.module.url(forResource: "message", withExtension: "txt")!
    return try! String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}
