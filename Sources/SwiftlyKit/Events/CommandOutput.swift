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
