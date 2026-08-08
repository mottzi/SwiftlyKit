/// An event emitted by a mutating SwiftlyKit operation.
public enum SwiftlyKitEvent: Sendable {
    case progress(OperationProgress)
    case output(CommandOutput)
}

/// An optional, awaited event observer.
public typealias EventHandler = @Sendable (SwiftlyKitEvent) async -> Void
