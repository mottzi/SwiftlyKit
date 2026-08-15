import Testing
@testable import SwiftlyKit

@Suite("Sensitive value redaction")
struct SensitiveValueRedactorTests {

    @Test("Redacts values split across chunks without delaying unrelated text")
    func splitValue() {

        var redactor = SensitiveValueRedactor(["split-secret"])

        let first = redactor.redact("before split-")
        let second = redactor.redact("secret after")
        let final = redactor.finish()

        #expect(first == "before ")
        #expect(second + final == "<redacted> after")
    }

    @Test("Uses the longest overlapping value and preserves incomplete text at end of stream")
    func overlappingValues() {

        var redactor = SensitiveValueRedactor(["token", "token-long"])

        #expect(redactor.redact("token") == "")
        #expect(redactor.redact("-long and tok") == "<redacted> and ")
        #expect(redactor.finish() == "tok")
    }

    @Test("Redacts repeated Unicode values")
    func unicodeValues() {

        var redactor = SensitiveValueRedactor(["sécret"])

        let output = redactor.redact("sé")
            + redactor.redact("cret/sécret")
            + redactor.finish()

        #expect(output == "<redacted>/<redacted>")
    }

}
