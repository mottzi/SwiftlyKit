/// A progress, command, or subprocess output event from a mutating Triple operation.
public enum TripleEvent: Sendable {

    /// Reports the current workflow activity and human-readable detail.
    case progress(OperationProgress)

    /// Reports a delegated command before Triple attempts to start it.
    case command(CommandInvocation)

    /// Forwards decoded output from a delegated mutating command.
    case output(CommandOutputChunk)

}

extension TripleEvent {

    /// An asynchronous observer that Triple awaits for each emitted event.
    /// The observer must not await another mutating Triple operation.
    public typealias Handler = @Sendable (TripleEvent) async -> Void

}
