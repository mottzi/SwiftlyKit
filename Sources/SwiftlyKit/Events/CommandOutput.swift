/// A bounded chunk of subprocess output.
public struct CommandOutput: Sendable {

    public let stream: Stream
    public let text: String

    private init(stream: Stream, text: String) {
        self.stream = stream
        self.text = text
    }

}

extension CommandOutput {

    static func handler(for eventHandler: EventHandler?) -> SubprocessOutputHandler? {

        guard let eventHandler else { return nil }

        return { stream, text in
            await eventHandler(.output(CommandOutput(stream: stream, text: text)))
        }
    }

}

extension CommandOutput {
    
    public enum Stream: Sendable, Hashable {
        case standardOutput
        case standardError
    }
    
}
