import Foundation
import Testing
@testable import SwiftlyKit

@Suite("ELF executable verification")
struct ELFExecutableVerifierTests {

    @Test("Accepts both supported static architectures")
    func acceptsStaticExecutables() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            for architecture in [LinuxArchitecture.arm64, .x86_64] {
                let url = directory.appending(path: String(describing: architecture))
                try writeELF(to: url, architecture: architecture)
                try ELFExecutableVerifier.verify(url, architecture: architecture)
            }
        }
    }

    @Test("Rejects architecture mismatch, interpreter, and needed library")
    func rejectsInvalidStaticExpectations() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let mismatch = directory.appending(path: "mismatch")
            try writeELF(to: mismatch, architecture: .arm64)
            #expect(throws: SwiftPMError.invalidExecutable(
                "The ELF architecture does not match the target."
            )) {
                try ELFExecutableVerifier.verify(mismatch, architecture: .x86_64)
            }

            let interpreter = directory.appending(path: "interpreter")
            try writeELF(to: interpreter, architecture: .arm64, secondSegment: 3)
            #expect(throws: SwiftPMError.invalidExecutable(
                "The ELF declares a dynamic interpreter or required library."
            )) {
                try ELFExecutableVerifier.verify(interpreter, architecture: .arm64)
            }

            let needed = directory.appending(path: "needed")
            try writeELF(to: needed, architecture: .arm64, secondSegment: 2, dynamicTag: 1)
            #expect(throws: SwiftPMError.invalidExecutable(
                "The ELF declares a dynamic interpreter or required library."
            )) {
                try ELFExecutableVerifier.verify(needed, architecture: .arm64)
            }
        }
    }

    @Test("Rejects non-executable files and malformed ELF structure")
    func rejectsMalformedExecutables() throws {

        try withTemporaryDirectory(prefix: "SwiftlyKit-SwiftPM") { directory in
            let nonExecutable = directory.appending(path: "non-executable")
            try writeELF(to: nonExecutable, architecture: .arm64)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: nonExecutable.path
            )
            #expect(throws: SwiftPMError.invalidExecutable(
                "The output is not an executable regular file."
            )) {
                try ELFExecutableVerifier.verify(nonExecutable, architecture: .arm64)
            }

            let truncated = directory.appending(path: "truncated")
            try Data([0x7f, 0x45, 0x4c, 0x46]).write(to: truncated)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: truncated.path)
            #expect(throws: SwiftPMError.invalidExecutable(
                "The output is not a little-endian ELF64 file."
            )) {
                try ELFExecutableVerifier.verify(truncated, architecture: .arm64)
            }

            let wrongType = directory.appending(path: "wrong-type")
            try writeELF(to: wrongType, architecture: .arm64)
            var wrongTypeData = try Data(contentsOf: wrongType)
            writeLittleEndian(UInt16(1), at: 16, into: &wrongTypeData)
            try wrongTypeData.write(to: wrongType)
            #expect(throws: SwiftPMError.invalidExecutable(
                "The ELF file is not executable."
            )) {
                try ELFExecutableVerifier.verify(wrongType, architecture: .arm64)
            }

            let noLoadableSegment = directory.appending(path: "no-loadable-segment")
            try writeELF(to: noLoadableSegment, architecture: .arm64)
            var noLoadData = try Data(contentsOf: noLoadableSegment)
            writeLittleEndian(UInt32(4), at: 64, into: &noLoadData)
            try noLoadData.write(to: noLoadableSegment)
            #expect(throws: SwiftPMError.invalidExecutable(
                "The ELF program headers are malformed."
            )) {
                try ELFExecutableVerifier.verify(noLoadableSegment, architecture: .arm64)
            }
        }
    }

}
