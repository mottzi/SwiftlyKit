import Foundation
import Testing
@testable import SwiftlyKit

@Suite("Build runtime ELF verification")
struct ELFExecutableVerifierTests {
    @Test("Accepts both supported static architectures")
    func acceptsStaticExecutables() throws {
        try withBuildRuntimeTemporaryDirectory { directory in
            for architecture in [LinuxArchitecture.arm64, .x86_64] {
                let url = directory.appending(path: String(describing: architecture))
                try writeELF(to: url, architecture: architecture)
                try ELFExecutableVerifier().verify(url, architecture: architecture)
            }
        }
    }

    @Test("Rejects architecture mismatch, interpreter, and needed library")
    func rejectsInvalidStaticExpectations() throws {
        try withBuildRuntimeTemporaryDirectory { directory in
            let mismatch = directory.appending(path: "mismatch")
            try writeELF(to: mismatch, architecture: .arm64)
            #expect(throws: BuildRuntimeError.self) {
                try ELFExecutableVerifier().verify(mismatch, architecture: .x86_64)
            }

            let interpreter = directory.appending(path: "interpreter")
            try writeELF(to: interpreter, architecture: .arm64, secondSegment: 3)
            #expect(throws: BuildRuntimeError.self) {
                try ELFExecutableVerifier().verify(interpreter, architecture: .arm64)
            }

            let needed = directory.appending(path: "needed")
            try writeELF(to: needed, architecture: .arm64, secondSegment: 2, dynamicTag: 1)
            #expect(throws: BuildRuntimeError.self) {
                try ELFExecutableVerifier().verify(needed, architecture: .arm64)
            }
        }
    }
}

func writeELF(
    to url: URL,
    architecture: LinuxArchitecture,
    secondSegment: UInt32? = nil,
    dynamicTag: UInt64 = 0
) throws {
    let count = secondSegment == nil ? 120 : 192
    var data = Data(repeating: 0, count: count)
    data.replaceSubrange(0..<7, with: [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1])
    write(UInt16(2), at: 16, into: &data)
    write(architecture.elfMachine, at: 18, into: &data)
    write(UInt64(64), at: 32, into: &data)
    write(UInt16(56), at: 54, into: &data)
    write(UInt16(secondSegment == nil ? 1 : 2), at: 56, into: &data)
    write(UInt32(1), at: 64, into: &data)
    write(UInt64(1), at: 64 + 48, into: &data)
    if let secondSegment {
        write(secondSegment, at: 120, into: &data)
        write(UInt64(176), at: 120 + 8, into: &data)
        write(UInt64(16), at: 120 + 32, into: &data)
        write(UInt64(dynamicTag), at: 176, into: &data)
    }
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func write<T: FixedWidthInteger>(_ value: T, at offset: Int, into data: inout Data) {
    for index in 0..<MemoryLayout<T>.size {
        data[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
    }
}

func withBuildRuntimeTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SwiftlyKit-BuildRuntime-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

func withBuildRuntimeTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "SwiftlyKit-BuildRuntime-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}
