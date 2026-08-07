import Foundation

struct SwiftPM: Sendable {
    
    let runner: any SubprocessRunning
    let verifier: ELFExecutableVerifier
    let publisher: AtomicOutputPublisher
    let validateEnvironment: @Sendable (LocalBuildEnvironment) throws -> Void
    
    init(
        runner: any SubprocessRunning = LiveSubprocessRunner(),
        verifier: ELFExecutableVerifier = ELFExecutableVerifier(),
        publisher: AtomicOutputPublisher = AtomicOutputPublisher(),
        validateEnvironment: @escaping @Sendable (LocalBuildEnvironment) throws -> Void = {
            try $0.validate()
        }
    ) {
        self.runner = runner
        self.verifier = verifier
        self.publisher = publisher
        self.validateEnvironment = validateEnvironment
    }
    
}
