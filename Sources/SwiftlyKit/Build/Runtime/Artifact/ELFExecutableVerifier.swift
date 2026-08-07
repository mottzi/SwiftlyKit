import Foundation

struct ELFExecutableVerifier: Sendable {
    
    func verify(_ url: URL, architecture: LinuxArchitecture) throws {
        
        do {
            try verifyContents(of: url, architecture: architecture)
        } catch let error as BuildRuntimeError {
            throw error
        } catch {
            throw BuildRuntimeError.invalidExecutable("The output could not be read for verification.")
        }
    }
    
    private func verifyContents(of url: URL, architecture: LinuxArchitecture) throws {
        
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              FileManager.default.isExecutableFile(atPath: url.path)
        else { throw BuildRuntimeError.invalidExecutable("The output is not an executable regular file.") }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let reader = Reader(data: data)
        guard data.count >= 64, Array(data.prefix(4)) == [0x7f, 0x45, 0x4c, 0x46],
              try reader.byte(4) == 2, try reader.byte(5) == 1, try reader.byte(6) == 1
        else { throw BuildRuntimeError.invalidExecutable("The output is not a little-endian ELF64 file.") }
        guard [UInt16(2), UInt16(3)].contains(try reader.uint16(16)) else {
            throw BuildRuntimeError.invalidExecutable("The ELF file is not executable.")
        }
        guard try reader.uint16(18) == architecture.elfMachine else {
            throw BuildRuntimeError.invalidExecutable("The ELF architecture does not match the target.")
        }

        let tableOffset = try reader.int(reader.uint64(32))
        let entrySize = Int(try reader.uint16(54))
        let entryCount = Int(try reader.uint16(56))
        guard entrySize >= 56, entryCount > 0 else { throw malformed }

        var hasLoadSegment = false
        for index in 0..<entryCount {
            let offset = try reader.add(tableOffset, try reader.multiply(index, entrySize))
            let type = try reader.uint32(offset)
            _ = try reader.uint64(offset + 48)
            if type == 1 { hasLoadSegment = true }
            if type == 3 { throw dynamicallyLinked }
            if type == 2, try hasNeededEntry(reader, headerOffset: offset) { throw dynamicallyLinked }
        }
        guard hasLoadSegment else { throw malformed }
    }
    
    private func hasNeededEntry(_ reader: Reader, headerOffset: Int) throws -> Bool {
        
        let offset = try reader.int(reader.uint64(headerOffset + 8))
        let size = try reader.int(reader.uint64(headerOffset + 32))
        guard size % 16 == 0 else { throw malformed }
        for displacement in stride(from: 0, to: size, by: 16) {
            let tag = try reader.uint64(try reader.add(offset, displacement))
            if tag == 0 { return false }
            if tag == 1 { return true }
        }
        return false
    }
    
    private var malformed: BuildRuntimeError {
        .invalidExecutable("The ELF program headers are malformed.")
    }

    private var dynamicallyLinked: BuildRuntimeError {
        .invalidExecutable("The ELF declares a dynamic interpreter or required library.")
    }

    private struct Reader {
        
        let data: Data
        
        func byte(_ offset: Int) throws -> UInt8 {
            guard data.indices.contains(offset) else { throw malformed }
            return data[offset]
        }

        func uint16(_ offset: Int) throws -> UInt16 {
            let bytes = try slice(offset, 2)
            return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        }

        func uint32(_ offset: Int) throws -> UInt32 {
            let bytes = try slice(offset, 4)
            return bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
        }

        func uint64(_ offset: Int) throws -> UInt64 {
            let bytes = try slice(offset, 8)
            return bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
        }

        func int(_ value: UInt64) throws -> Int {
            guard value <= UInt64(Int.max) else { throw malformed }
            return Int(value)
        }

        func add(_ lhs: Int, _ rhs: Int) throws -> Int {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else { throw malformed }
            return value
        }

        func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
            let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
            guard !overflow else { throw malformed }
            return value
        }

        private func slice(_ offset: Int, _ count: Int) throws -> Data {
            guard offset >= 0, count >= 0 else { throw malformed }
            let end = try add(offset, count)
            guard end <= data.count else { throw malformed }
            return data.subdata(in: offset..<end)
        }

        private var malformed: BuildRuntimeError {
            .invalidExecutable("The ELF program headers are malformed.")
        }
        
    }
    
}
