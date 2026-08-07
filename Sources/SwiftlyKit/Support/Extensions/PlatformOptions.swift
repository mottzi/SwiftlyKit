import Subprocess

extension PlatformOptions {
    
    static var swiftlyKitProcess: PlatformOptions {
        var options = PlatformOptions()
        options.createSession = true
        options.teardownSequence = [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(1))]
        return options
    }
    
}
