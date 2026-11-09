// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest

final class BundleUnpackerTests: XCTestCase {
    private struct Entry {
        let name: String
        let data: Data
        var method: UInt16 = 0
        var compressedData: Data?
        var corruptCRC = false
    }

    func testSuccessfullyExtractsStoredAndRawDeflatedEntries() throws {
        try withOutput { bundle, output in
            let stored = Data("base apk bytes".utf8)
            let deflated = Data("hello".utf8)
            try archive([
                Entry(name: "base.apk", data: stored),
                Entry(name: "config.apk", data: deflated, method: 8,
                      compressedData: Data([0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00]))
            ]).write(to: bundle)

            let names = try BundleUnpacker.unpack(bundle, into: output)

            XCTAssertEqual(names, ["base.apk", "config.apk"])
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("base.apk")), stored)
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("config.apk")), deflated)
        }
    }

    func testRollsBackFilesCreatedBeforeALaterExtractionFailure() throws {
        try withOutput { bundle, output in
            try archive([
                Entry(name: "base.apk", data: Data("base".utf8)),
                Entry(name: "split_config.apk", data: Data("bad split".utf8), corruptCRC: true)
            ]).write(to: bundle)

            XCTAssertThrowsError(try BundleUnpacker.unpack(bundle, into: output))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("base.apk").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("split_config.apk").path))
        }
    }

    func testRollsBackFilesAndNewDirectoriesAfterOBBFailure() throws {
        try withOutput { bundle, output in
            try archive([
                Entry(name: "base.apk", data: Data("base".utf8)),
                Entry(name: "Android/obb/com.example/main.1.com.example.obb",
                      data: Data("bad obb".utf8), corruptCRC: true)
            ]).write(to: bundle)

            XCTAssertThrowsError(try BundleUnpacker.unpack(bundle, into: output))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("base.apk").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("obb").path))
        }
    }

    func testFailurePreservesPreexistingFilesAndDirectories() throws {
        try withOutput { bundle, output in
            let existingFile = output.appendingPathComponent("config.apk")
            let existingBytes = Data("keep this file".utf8)
            try existingBytes.write(to: existingFile)
            let existingOBBDirectory = output.appendingPathComponent("obb", isDirectory: true)
            try FileManager.default.createDirectory(at: existingOBBDirectory, withIntermediateDirectories: false)
            let sentinel = existingOBBDirectory.appendingPathComponent("main.1.com.example.obb")
            let sentinelBytes = Data("keep this directory and file".utf8)
            try sentinelBytes.write(to: sentinel)
            try archive([
                Entry(name: "base.apk", data: Data("new base".utf8)),
                Entry(name: "Android/obb/com.example/main.1.com.example.obb", data: Data("replacement".utf8))
            ]).write(to: bundle)

            XCTAssertThrowsError(try BundleUnpacker.unpack(bundle, into: output))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("base.apk").path))
            XCTAssertEqual(try Data(contentsOf: existingFile), existingBytes)
            XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: existingOBBDirectory.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    func testRejectsInvalidZIPWithoutCreatingOutputs() throws {
        try withOutput { bundle, output in
            try Data("not a zip archive".utf8).write(to: bundle)

            XCTAssertThrowsError(try BundleUnpacker.unpack(bundle, into: output))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
        }
    }

    func testRejectsIncorrectCRCAndRollsBackTheCurrentFile() throws {
        try withOutput { bundle, output in
            try archive([
                Entry(name: "base.apk", data: Data("payload with a bad checksum".utf8), corruptCRC: true)
            ]).write(to: bundle)

            XCTAssertThrowsError(try BundleUnpacker.unpack(bundle, into: output))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("base.apk").path))
        }
    }

    private func withOutput(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("fixture.xapk")
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(bundle, output)
    }

    private func archive(_ entries: [Entry]) -> Data {
        var localRecords = Data()
        var centralDirectory = Data()

        for entry in entries {
            let name = Data(entry.name.utf8)
            let payload = entry.compressedData ?? entry.data
            let checksum = crc32(entry.data) ^ (entry.corruptCRC ? 1 : 0)
            let localOffset = UInt32(localRecords.count)

            localRecords.appendLE(UInt32(0x0403_4b50))
            localRecords.appendLE(UInt16(20))
            localRecords.appendLE(UInt16(0))
            localRecords.appendLE(entry.method)
            localRecords.appendLE(UInt16(0))
            localRecords.appendLE(UInt16(0))
            localRecords.appendLE(checksum)
            localRecords.appendLE(UInt32(payload.count))
            localRecords.appendLE(UInt32(entry.data.count))
            localRecords.appendLE(UInt16(name.count))
            localRecords.appendLE(UInt16(0))
            localRecords.append(name)
            localRecords.append(payload)

            centralDirectory.appendLE(UInt32(0x0201_4b50))
            centralDirectory.appendLE(UInt16(20))
            centralDirectory.appendLE(UInt16(20))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(entry.method)
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(checksum)
            centralDirectory.appendLE(UInt32(payload.count))
            centralDirectory.appendLE(UInt32(entry.data.count))
            centralDirectory.appendLE(UInt16(name.count))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt32(0))
            centralDirectory.appendLE(localOffset)
            centralDirectory.append(name)
        }

        var result = localRecords
        let centralOffset = UInt32(result.count)
        result.append(centralDirectory)
        let centralSize = UInt32(centralDirectory.count)
        result.appendLE(UInt32(0x0605_4b50))
        result.appendLE(UInt16(0))
        result.appendLE(UInt16(0))
        result.appendLE(UInt16(entries.count))
        result.appendLE(UInt16(entries.count))
        result.appendLE(centralSize)
        result.appendLE(centralOffset)
        result.appendLE(UInt16(0))
        return result
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 0 ? crc >> 1 : 0xedb8_8320 ^ (crc >> 1) }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
