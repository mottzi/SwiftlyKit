/// A progress, command, or subprocess output event from a mutating SwiftlyKit operation.
public enum SwiftlyKitEvent: Sendable {

    /// Reports the current workflow activity and optional preparation component.
    case progress(OperationProgress)

    /// Reports a delegated command before SwiftlyKit attempts to start it.
    case command(CommandInvocation)

    /// Forwards decoded output from a delegated mutating command.
    case output(CommandOutputChunk)

}

extension SwiftlyKitEvent {

    /// An asynchronous observer that SwiftlyKit awaits for each emitted event.
    /// The observer must not await another mutating SwiftlyKit operation.
    public typealias Handler = @Sendable (SwiftlyKitEvent) async -> Void

}
