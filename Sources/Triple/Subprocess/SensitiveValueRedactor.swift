import Foundation

/// Removes exact sensitive values from text without exposing values split across input chunks.
struct SensitiveValueRedactor {

    private let values: [String]
    private var pending = ""

    /// Creates a streaming redactor for exact nonempty values.
    init(_ values: [String]) {
        self.values = Array(Set(values.filter { !$0.isEmpty })).sorted { first, second in
            first.count > second.count
        }
    }

    /// Returns safe text and retains an incomplete sensitive-value prefix for the next input chunk.
    mutating func redact(_ text: String) -> String {

        guard !values.isEmpty else { return text }

        pending.append(text)
        return consume(final: false)
    }

    /// Returns the final safe text after no more input can complete a sensitive value.
    mutating func finish() -> String {

        guard !values.isEmpty else { return "" }
        return consume(final: true)
    }

}

extension SensitiveValueRedactor {

    private mutating func consume(final: Bool) -> String {

        var output = ""
        while !pending.isEmpty {
            let matches = values.filter { pending.hasPrefix($0) }
            let canGrow = values.contains { value in
                value.count > pending.count && value.hasPrefix(pending)
            }

            if let match = matches.first, final || !canGrow {
                pending.removeFirst(match.count)
                output.append(Self.placeholder)
                continue
            }
            if !final && canGrow { break }

            output.append(pending.removeFirst())
        }

        return output
    }

}

extension SensitiveValueRedactor {

    static let placeholder = "<redacted>"

}
