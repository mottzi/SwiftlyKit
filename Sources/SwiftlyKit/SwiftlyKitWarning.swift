/// A non-fatal warning emitted while completing an operation.
public struct SwiftlyKitWarning: Sendable {
    
    public let message: String
    
    init(message: String) {
        self.message = message
    }
    
}
