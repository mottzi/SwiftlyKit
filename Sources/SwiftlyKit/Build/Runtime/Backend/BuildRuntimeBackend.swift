import Foundation

struct BuildRuntimeBackend: Sendable {
    
    let runner: any BuildRuntimeProcessRunning
    let verifier: ELFExecutableVerifier
    let publisher: AtomicOutputPublisher
    
    init(
        runner: any BuildRuntimeProcessRunning = LiveBuildRuntimeProcessRunner(),
        verifier: ELFExecutableVerifier = ELFExecutableVerifier(),
        publisher: AtomicOutputPublisher = AtomicOutputPublisher()
    ) {
        self.runner = runner
        self.verifier = verifier
        self.publisher = publisher
    }
    
}
