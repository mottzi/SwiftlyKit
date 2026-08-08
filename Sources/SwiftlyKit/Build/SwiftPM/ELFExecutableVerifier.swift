import Foundation

/// Verifier for static ELF64 build outputs for supported Linux architectures.
enum ELFExecutableVerifier {

    static func verify(_ url: URL, architecture: LinuxArchitecture) throws(SwiftPMError) {

        do {
            try verifyContents(of: url, architecture: architecture)
        } catch let error as SwiftPMError {
            throw error
        } catch {
            throw SwiftPMError.invalidExecutable(
                "The output could not be read for verification: \(error.localizedDescription)"
            )
        }
    }

}

extension ELFExecutableVerifier {

    private static func verifyContents(of url: URL, architecture: LinuxArchitecture) throws {

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])

        guard values.isRegularFile == true
        else { throw SwiftPMError.invalidExecutable("The output is not an executable regular file.") }
        guard values.isSymbolicLink == false
        else { throw SwiftPMError.invalidExecutable("The output is not an executable regular file.") }
        guard FileManager.default.isExecutableFile(atPath: url.path)
        else { throw SwiftPMError.invalidExecutable("The output is not an executable regular file.") }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let reader = Reader(data: data)

        guard try isLittleEndianELF64(reader)
        else { throw SwiftPMError.invalidExecutable("The output is not a little-endian ELF64 file.") }

        let fileTypeRawValue = try reader.uint16(at: 16)
        guard ExecutableFileType(rawValue: fileTypeRawValue) != nil
        else { throw SwiftPMError.invalidExecutable("The ELF file is not executable.") }

        guard try reader.uint16(at: 18) == architecture.elfMachine
        else { throw SwiftPMError.invalidExecutable("The ELF architecture does not match the target.") }

        let programHeaderTableOffsetRawValue = try reader.uint64(at: 32)
        let programHeaderTableOffset = try reader.int(from: programHeaderTableOffsetRawValue)
        let programHeaderSize = Int(try reader.uint16(at: 54))
        let programHeaderCount = Int(try reader.uint16(at: 56))

        guard programHeaderSize >= 56 else { throw malformedError }
        guard programHeaderCount > 0 else { throw malformedError }

        var hasLoadableSegment = false

        for index in 0..<programHeaderCount {
            let programHeaderDisplacement = try reader.multiply(index, programHeaderSize)
            let programHeaderOffset = try reader.add(programHeaderTableOffset, programHeaderDisplacement)
            try reader.validateRange(at: programHeaderOffset, byteCount: 56)

            let programHeaderTypeRawValue = try reader.uint32(at: programHeaderOffset)
            switch ProgramHeaderType(rawValue: programHeaderTypeRawValue) {
                case .loadable: hasLoadableSegment = true
                case .interpreter: throw dynamicallyLinkedError
                case .dynamicLinking:
                    if try declaresNeededLibrary(reader, programHeaderOffset: programHeaderOffset) {
                        throw dynamicallyLinkedError
                    }
                case nil: continue
            }
        }

        guard hasLoadableSegment else { throw malformedError }
    }

}

extension ELFExecutableVerifier {

    private static func isLittleEndianELF64(_ reader: Reader) throws -> Bool {

        guard reader.data.count >= 64 else { return false }
        guard reader.data.starts(with: [0x7f, 0x45, 0x4c, 0x46]) else { return false }

        let fileClass = try reader.byte(at: 4)
        let byteOrder = try reader.byte(at: 5)
        let formatVersion = try reader.byte(at: 6)

        return fileClass == 2 && byteOrder == 1 && formatVersion == 1
    }

    private static func declaresNeededLibrary(_ reader: Reader, programHeaderOffset: Int) throws -> Bool {

        let entriesOffsetRawValue = try reader.uint64(at: programHeaderOffset + 8)
        let entriesOffset = try reader.int(from: entriesOffsetRawValue)
        let entriesSizeRawValue = try reader.uint64(at: programHeaderOffset + 32)
        let entriesSize = try reader.int(from: entriesSizeRawValue)
        let entrySize = 16

        guard entriesSize.isMultiple(of: entrySize) else { throw malformedError }

        for displacement in stride(from: 0, to: entriesSize, by: entrySize) {
            let entryOffset = try reader.add(entriesOffset, displacement)

            let entryTagRawValue = try reader.uint64(at: entryOffset)
            switch DynamicEntryTag(rawValue: entryTagRawValue) {
                case .end: return false
                case .neededLibrary: return true
                case nil: continue
            }
        }

        return false
    }

}

extension ELFExecutableVerifier {

    /// Reader for little-endian ELF values with checks for invalid offsets and overflow.
    private struct Reader {

        let data: Data

        func byte(at offset: Int) throws -> UInt8 {
            guard data.indices.contains(offset) else { throw ELFExecutableVerifier.malformedError }
            return data[offset]
        }

        func uint16(at offset: Int) throws -> UInt16 {
            let bytes = try slice(at: offset, byteCount: 2)
            return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        }

        func uint32(at offset: Int) throws -> UInt32 {
            let bytes = try slice(at: offset, byteCount: 4)
            return bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
        }

        func uint64(at offset: Int) throws -> UInt64 {
            let bytes = try slice(at: offset, byteCount: 8)
            return bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
        }

        func int(from value: UInt64) throws -> Int {
            guard value <= UInt64(Int.max) else { throw ELFExecutableVerifier.malformedError }
            return Int(value)
        }

        func add(_ lhs: Int, _ rhs: Int) throws -> Int {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else { throw ELFExecutableVerifier.malformedError }
            return value
        }

        func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
            let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
            guard !overflow else { throw ELFExecutableVerifier.malformedError }
            return value
        }

        func validateRange(at offset: Int, byteCount: Int) throws {

            guard offset >= 0 else { throw ELFExecutableVerifier.malformedError }
            guard byteCount >= 0 else { throw ELFExecutableVerifier.malformedError }

            let end = try add(offset, byteCount)
            guard end <= data.count else { throw ELFExecutableVerifier.malformedError }
        }

        private func slice(at offset: Int, byteCount: Int) throws -> Data {
            try validateRange(at: offset, byteCount: byteCount)
            let end = offset + byteCount
            return data.subdata(in: offset..<end)
        }

    }

}

extension ELFExecutableVerifier {

    private enum ExecutableFileType: UInt16 {
        case executable = 2
        case positionIndependent = 3
    }

    private enum ProgramHeaderType: UInt32 {
        case loadable = 1
        case dynamicLinking = 2
        case interpreter = 3
    }

    private enum DynamicEntryTag: UInt64 {
        case end = 0
        case neededLibrary = 1
    }

}

extension ELFExecutableVerifier {

    private static let malformedError = SwiftPMError.invalidExecutable(
        "The ELF program headers are malformed."
    )

    private static let dynamicallyLinkedError = SwiftPMError.invalidExecutable(
        "The ELF declares a dynamic interpreter or required library."
    )

}
