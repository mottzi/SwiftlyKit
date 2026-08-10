import Foundation
@testable import SwiftlyKit

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
