/// A decoded text chunk from standard output or standard error of a delegated command.
public struct CommandOutput: Sendable {

    /// The standard stream that produced this text chunk.
    public let stream: Stream

    /// Decoded subprocess text with its original line breaks.
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
    
    /// A standard subprocess output stream.
    public enum Stream: Sendable {
        /// Standard output from a delegated subprocess.
        case standardOutput

        /// Standard error from a delegated subprocess.
        case standardError
    }
    
}
