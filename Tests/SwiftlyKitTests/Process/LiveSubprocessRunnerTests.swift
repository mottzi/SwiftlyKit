import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Subprocess runner")
struct LiveSubprocessRunnerTests {
    
    @Test("Captures both streams and awaits output delivery")
    func captureAndStreamOutput() async throws {
        
        let recorder = OutputRecorder()
        let result = try await LiveSubprocessRunner().run(
            SubprocessCommand(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", "printf standard; printf diagnostic >&2"]
            ),
            onOutput: { stream, text in
                await recorder.record(stream, text)
            }
        )
        
        #expect(result.succeeded)
        #expect(result.standardOutput == "standard")
        #expect(result.standardError == "diagnostic")
        let output = await recorder.output
        #expect(output[.standardOutput] == "standard")
        #expect(output[.standardError] == "diagnostic")
    }
    
}

private actor OutputRecorder {
    
    private(set) var output: [OutputStream: String] = [:]
    
    func record(_ stream: SubprocessOutput, _ text: String) {
        let key: OutputStream = switch stream {
            case .standardOutput: .standardOutput
            case .standardError: .standardError
        }
        output[key, default: ""].append(text)
    }
    
    enum OutputStream: Hashable {
        case standardOutput
        case standardError
    }
    
}
