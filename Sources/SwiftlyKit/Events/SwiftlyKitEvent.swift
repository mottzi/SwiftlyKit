/// A progress or subprocess output event from a mutating SwiftlyKit operation.
public enum SwiftlyKitEvent: Sendable {

    /// Reports the current workflow activity and optional preparation component.
    case progress(OperationProgress)

    /// Forwards decoded output from a delegated mutating command.
    case output(CommandOutputChunk)

}

extension SwiftlyKitEvent {

    /// An asynchronous observer that SwiftlyKit awaits for each emitted event.
    public typealias Handler = @Sendable (SwiftlyKitEvent) async -> Void

}
