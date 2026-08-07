/// A bounded chunk of subprocess output.
public struct CommandOutput: Sendable {
    
    public enum Stream: Sendable, Hashable {
        
        case standardOutput
        case standardError
        
    }
    
    public let stream: Stream
    public let text: String
    
    init(stream: Stream, text: String) {
        self.stream = stream
        self.text = text
    }
    
}

extension CommandOutput {

    static func handler(for eventHandler: EventHandler?) -> SubprocessOutputHandler? {
        guard let eventHandler else { return nil }
        return { output, text in
            let stream: Stream = switch output {
                case .standardOutput: .standardOutput
                case .standardError: .standardError
            }
            await eventHandler(.output(CommandOutput(stream: stream, text: text)))
        }
    }

}
