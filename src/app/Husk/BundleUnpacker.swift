// SPDX-License-Identifier: GPL-2.0-or-later
import Compression
import Darwin
import Foundation

/// Takes the APKs out of an app bundle: an .xapk (APKPure), .apkm (APKMirror) or .apks (bundletool), which are zip files holding a base APK and its splits and asset packs.
///
/// Only what is needed is read: the zip's central directory, then each APK's bytes copied across in chunks. An APK inside a bundle is usually stored, not compressed (it is
/// already a zip); a deflated one is inflated as it streams. Either way a 200 MB asset pack costs a few megabytes of memory, not 200.
enum BundleUnpacker {
    static let extensions: Set<String> = ["xapk", "apkm", "apks"]
    private static let maxEntryUncompressedSize: UInt64 = 2 << 30
    private static let maxBundleUncompressedSize: UInt64 = 4 << 30

    enum Failure: LocalizedError {
        case notAZip, unsupported(String)
        var errorDescription: String? {
            switch self {
            case .notAZip: return "That file is not a bundle Husk can read."
            case .unsupported(let why): return why
            }
        }
    }

    /// Whether an APK is a split or an asset pack, as the bundle formats name them, rather than the app itself.
    static func isSplit(_ name: String) -> Bool {
        let n = name.lowercased()
        if n == "base.apk" || n == "base-master.apk" { return false }
        return n.hasPrefix("config.") || n.hasPrefix("split_") || n.hasPrefix("asset_pack") || n.hasPrefix("base-") || n.hasPrefix("install_time")
    }

    /// The fallback order when an APK's manifest cannot be read: the app itself, then its 64-bit libraries and asset packs,
    /// then the language and screen-density splits, which it does not need.
    ///
    /// `siblings` are the app's other APK names. Besides Android's own split names (config.*, split_*), a split may be named
    /// after the base: com.game.apk beside com.game.config.arm64_v8a.apk and com.game.SomeAssetPack.apk, the way Google
    /// Play hands them out. A name that is another's name plus ".something" is that one's split.
    static func rank(_ name: String, siblings: [String] = []) -> Int {
        let n = name.lowercased()
        let named = siblings.contains { other in
            let o = other.lowercased()
            guard o != n, o.hasSuffix(".apk") else { return false }
            return n.hasPrefix(String(o.dropLast(4)) + ".")
        }
        if !isSplit(n) && !named { return 0 }
        if n.contains("arm64") { return 1 }
        if n.hasPrefix("asset_pack") || n.hasPrefix("install_time") || (named && !n.contains(".config.")) { return 2 }
        return 3
    }

    /// Read each manifest once, before sorting. A manifest-confirmed base takes precedence over every filename guess;
    /// a manifest-confirmed split can never be promoted to base just because it is named models.apk or textures.apk.
    static func orderedAPKs(_ paths: [String], manifest: (String) -> Data?) -> [String] {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let ranked = paths.map { path -> (path: String, priority: Int) in
            let name = (path as NSString).lastPathComponent
            let fallback = rank(name, siblings: names)
            let split = manifest(path).flatMap { ApkMetadata.isSplit($0) }
            let priority: Int
            switch split {
            case false?: priority = -1
            case true?: priority = fallback == 0 ? 2 : fallback
            case nil: priority = fallback
            }
            return (path, priority)
        }
        return ranked.sorted {
            $0.priority != $1.priority ? $0.priority < $1.priority : $0.path < $1.path
        }.map { $0.path }
    }

    private struct CreatedFile {
        let url: URL
        let device: dev_t
        let inode: ino_t
    }

    private struct CreatedDirectory {
        let url: URL
        let device: dev_t
        let inode: ino_t
    }

    /// Copies every APK in `bundle` into `dir`, and its expansion files (Android/obb/<package>/*.obb, which XAPKs carry) into `dir`/obb. Returns their names.
    @discardableResult
    static func unpack(_ bundle: URL, into dir: URL) throws -> [String] {
        var createdFiles: [CreatedFile] = []
        var createdDirectories: [CreatedDirectory] = []
        do {
            return try unpack(bundle, into: dir, createdFiles: &createdFiles,
                              createdDirectories: &createdDirectories)
        } catch {
            rollback(files: createdFiles, directories: createdDirectories)
            throw error
        }
    }

    private static func unpack(_ bundle: URL, into dir: URL, createdFiles: inout [CreatedFile],
                               createdDirectories: inout [CreatedDirectory]) throws -> [String] {
        let scoped = bundle.startAccessingSecurityScopedResource()
        defer { if scoped { bundle.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: bundle)
        defer { try? file.close() }

        let size = try file.seekToEnd()
        let tail = min(size, 70_000)
        try file.seek(toOffset: size - tail)
        let bytes = [UInt8](try readExactly(file, count: Int(tail)))
        guard bytes.count >= 22 else { throw Failure.notAZip }
        var e = bytes.count - 22
        while e >= 0 {
            if bytes[e] == 0x50 && bytes[e + 1] == 0x4b && bytes[e + 2] == 5 && bytes[e + 3] == 6,
               e + 22 + Int(le16(bytes, e + 20)) == bytes.count { break }
            e -= 1
        }
        guard e >= 0, le16(bytes, e + 4) == 0, le16(bytes, e + 6) == 0 else { throw Failure.notAZip }
        let eocdDiskCount = UInt64(le16(bytes, e + 8))
        let eocdCount = UInt64(le16(bytes, e + 10))
        let eocdDirSize = UInt64(le32(bytes, e + 12))
        let eocdDirOffset = UInt64(le32(bytes, e + 16))
        var count = eocdCount, dirSize = eocdDirSize, dirOffset = eocdDirOffset
        let eocdOffset = size - tail + UInt64(e)
        var directoryLimit = eocdOffset

        if eocdDiskCount == 0xffff || eocdDirOffset == 0xffff_ffff || eocdCount == 0xffff || eocdDirSize == 0xffff_ffff {
            // Zip64 locator and end record must be single-disk and contiguous with the ordinary EOCD.
            guard e >= 20, le32(bytes, e - 20) == 0x0706_4b50,
                  le32(bytes, e - 16) == 0, le32(bytes, e - 4) == 1 else { throw Failure.notAZip }
            let locatorOffset = eocdOffset - 20
            let recordOffset = le64(bytes, e - 12)
            guard recordOffset <= locatorOffset, locatorOffset - recordOffset >= 56 else { throw Failure.notAZip }
            try file.seek(toOffset: recordOffset)
            let r = [UInt8](try readExactly(file, count: 56))
            let recordSize = le64(r, 4)
            guard le32(r, 0) == 0x0606_4b50, recordSize >= 44,
                  recordSize <= UInt64.max - 12, recordOffset <= locatorOffset,
                  recordSize + 12 == locatorOffset - recordOffset,
                  le32(r, 16) == 0, le32(r, 20) == 0 else { throw Failure.notAZip }
            let diskCount = le64(r, 24)
            count = le64(r, 32)
            guard diskCount == count,
                  eocdDiskCount == 0xffff || eocdDiskCount == diskCount,
                  eocdCount == 0xffff || eocdCount == count,
                  eocdDirSize == 0xffff_ffff || eocdDirSize == le64(r, 40),
                  eocdDirOffset == 0xffff_ffff || eocdDirOffset == le64(r, 48) else { throw Failure.notAZip }
            dirSize = le64(r, 40); dirOffset = le64(r, 48)
            directoryLimit = recordOffset
        } else {
            guard eocdDiskCount == eocdCount else { throw Failure.notAZip }
        }

        // Bound untrusted metadata before converting UInt64 to Int or allocating the directory buffer.
        guard dirOffset <= directoryLimit, dirSize <= directoryLimit - dirOffset,
              dirSize <= UInt64(64 << 20), dirSize <= UInt64(Int.max), count <= dirSize / 46 else { throw Failure.notAZip }
        let directorySize = Int(dirSize), entryCount = Int(count)
        try file.seek(toOffset: dirOffset)
        let cd = [UInt8](try readExactly(file, count: directorySize))

        var names: [String] = []
        var outputNames = Set<String>()
        var declaredOutput: UInt64 = 0
        var totalWritten: UInt64 = 0
        var p = 0
        for _ in 0..<entryCount {
            guard p + 46 <= cd.count, le32(cd, p) == 0x0201_4b50 else { throw Failure.notAZip }
            let entryStart = p
            let flags = le16(cd, p + 8), method = le16(cd, p + 10)
            let expectedCRC = le32(cd, p + 16)
            let compressed32 = le32(cd, p + 20), uncompressed32 = le32(cd, p + 24)
            var compressed = UInt64(compressed32), uncompressed = UInt64(uncompressed32)
            let nameLen = Int(le16(cd, p + 28)), extraLen = Int(le16(cd, p + 30)), commentLen = Int(le16(cd, p + 32))
            var localOffset = UInt64(le32(cd, p + 42))
            var diskStart = UInt32(le16(cd, p + 34))
            guard p + 46 + nameLen + extraLen + commentLen <= cd.count else { throw Failure.notAZip }
            let nameBytes = cd[(p + 46)..<(p + 46 + nameLen)]
            let name = String(decoding: nameBytes, as: UTF8.self)
            var zip64Seen = false
            var x = p + 46 + nameLen
            let xend = x + extraLen
            while x < xend {
                guard x + 4 <= xend else { throw Failure.notAZip }
                let id = le16(cd, x), len = Int(le16(cd, x + 2))
                guard len <= xend - x - 4 else { throw Failure.notAZip }
                let fieldEnd = x + 4 + len
                if id == 1 {
                    guard !zip64Seen else { throw Failure.notAZip }
                    zip64Seen = true
                    var q = x + 4
                    if uncompressed32 == 0xffff_ffff { guard q + 8 <= fieldEnd else { throw Failure.notAZip }; uncompressed = le64(cd, q); q += 8 }
                    if compressed32 == 0xffff_ffff { guard q + 8 <= fieldEnd else { throw Failure.notAZip }; compressed = le64(cd, q); q += 8 }
                    if localOffset == 0xffff_ffff { guard q + 8 <= fieldEnd else { throw Failure.notAZip }; localOffset = le64(cd, q); q += 8 }
                    if diskStart == 0xffff { guard q + 4 <= fieldEnd else { throw Failure.notAZip }; diskStart = le32(cd, q); q += 4 }
                }
                x = fieldEnd
            }
            guard diskStart == 0 else { throw Failure.notAZip }
            if (compressed32 == 0xffff_ffff || uncompressed32 == 0xffff_ffff ||
                le32(cd, entryStart + 42) == 0xffff_ffff || le16(cd, entryStart + 34) == 0xffff) && !zip64Seen {
                throw Failure.notAZip
            }
            p += 46 + nameLen + extraLen + commentLen

            let base = (name as NSString).lastPathComponent
            let lower = base.lowercased()
            let isOBB = lower.hasSuffix(".obb")
            guard lower.hasSuffix(".apk") || isOBB, !name.hasSuffix("/"), !base.hasPrefix("."),
                  base != ".", base != "..", !base.contains("\0") else { continue }
            let outputName = (isOBB ? "obb/" : "") + lower
            guard outputNames.insert(outputName).inserted else {
                throw Failure.unsupported("The bundle contains more than one file named \(base).")
            }
            let (newDeclaredOutput, declaredOverflow) = declaredOutput.addingReportingOverflow(uncompressed)
            guard !declaredOverflow, uncompressed <= Self.maxEntryUncompressedSize,
                  newDeclaredOutput <= Self.maxBundleUncompressedSize else {
                throw Failure.unsupported("The bundle exceeds Husk's per-file or total unpacking limit.")
            }
            declaredOutput = newDeclaredOutput
            guard method == 0 || method == 8,
                  flags & 0x2041 == 0,
                  (method == 8 || flags & 0x0006 == 0) else {
                throw Failure.unsupported("\(base) is encrypted or uses ZIP features Husk cannot unpack.")
            }
            let supportedFlags: UInt16 = method == 8 ? 0x080e : 0x0808
            guard flags & ~supportedFlags == 0 else { throw Failure.unsupported("\(base) uses ZIP flags Husk cannot unpack.") }

            // Validate the local header and its variable fields before seeking to or reading the payload.
            guard localOffset <= directoryLimit, directoryLimit - localOffset >= 30 else { throw Failure.notAZip }
            try file.seek(toOffset: localOffset)
            let lh = [UInt8](try readExactly(file, count: 30))
            let localNameLen = Int(le16(lh, 26)), localExtraLen = Int(le16(lh, 28))
            let localHeaderLength = 30 + localNameLen + localExtraLen
            guard le32(lh, 0) == 0x0403_4b50, le16(lh, 6) == flags, le16(lh, 8) == method,
                  UInt64(localHeaderLength) <= directoryLimit - localOffset else { throw Failure.notAZip }
            let localName = try readExactly(file, count: localNameLen)
            guard localName == Data(nameBytes) else { throw Failure.notAZip }
            let localExtra = [UInt8](try readExactly(file, count: localExtraLen))
            let dataStart = localOffset + UInt64(localHeaderLength)
            var localCompressed = UInt64(le32(lh, 18)), localUncompressed = UInt64(le32(lh, 22))
            var localZip64Seen = false
            var lx = 0
            while lx < localExtra.count {
                guard lx + 4 <= localExtra.count else { throw Failure.notAZip }
                let id = le16(localExtra, lx), len = Int(le16(localExtra, lx + 2))
                guard len <= localExtra.count - lx - 4 else { throw Failure.notAZip }
                let fieldEnd = lx + 4 + len
                if id == 1 {
                    guard !localZip64Seen else { throw Failure.notAZip }
                    localZip64Seen = true
                    var q = lx + 4
                    if localUncompressed == 0xffff_ffff { guard q + 8 <= fieldEnd else { throw Failure.notAZip }; localUncompressed = le64(localExtra, q); q += 8 }
                    if localCompressed == 0xffff_ffff { guard q + 8 <= fieldEnd else { throw Failure.notAZip }; localCompressed = le64(localExtra, q) }
                }
                lx = fieldEnd
            }
            guard (le32(lh, 18) != 0xffff_ffff && le32(lh, 22) != 0xffff_ffff) || localZip64Seen else { throw Failure.notAZip }
            let hasDescriptor = flags & 8 != 0
            if hasDescriptor {
                let localCRC = le32(lh, 14)
                guard localCRC == 0 || localCRC == expectedCRC,
                      localCompressed == 0 || localCompressed == 0xffff_ffff || localCompressed == compressed,
                      localUncompressed == 0 || localUncompressed == 0xffff_ffff || localUncompressed == uncompressed else { throw Failure.notAZip }
            } else {
                guard le32(lh, 14) == expectedCRC, localCompressed == compressed, localUncompressed == uncompressed else { throw Failure.notAZip }
            }
            guard dataStart <= directoryLimit, compressed <= directoryLimit - dataStart,
                  method != 0 || compressed == uncompressed else { throw Failure.notAZip }
            try file.seek(toOffset: dataStart)

            // An expansion file goes to obb/ under its own name: the runtime finds it there when the game asks for Android/obb/<package>/<name>.
            let destDir = isOBB ? dir.appendingPathComponent("obb", isDirectory: true) : dir
            try ensureDirectory(at: destDir, createdDirectories: &createdDirectories)
            let dest = destDir.appendingPathComponent(base)
            let out = try createOutput(at: dest, createdFiles: &createdFiles)
            do {
                var written: UInt64 = 0
                var checksum: UInt32 = 0
                var inflate: OutputFilter?
                if method == 8 {
                    inflate = try OutputFilter(.decompress, using: .zlib) { data in
                        guard let data else { return }
                        let next = written.addingReportingOverflow(UInt64(data.count))
                        let bundleNext = totalWritten.addingReportingOverflow(UInt64(data.count))
                        guard !next.overflow, next.partialValue <= uncompressed,
                              !bundleNext.overflow, bundleNext.partialValue <= Self.maxBundleUncompressedSize else {
                            throw Failure.unsupported("\(base) expanded beyond Husk's unpacking limit.")
                        }
                        checksum = Self.crc32(checksum, data)
                        try out.write(contentsOf: data)
                        written = next.partialValue
                        totalWritten = bundleNext.partialValue
                    }
                }
                var left = compressed
                while left > 0 {
                    let chunk = Int(min(left, 4 << 20))
                    let data = try readExactly(file, count: chunk)
                    if let inflate {
                        try inflate.write(data)
                    } else {
                        let next = written.addingReportingOverflow(UInt64(data.count))
                        let bundleNext = totalWritten.addingReportingOverflow(UInt64(data.count))
                        guard !next.overflow, next.partialValue <= uncompressed,
                              !bundleNext.overflow, bundleNext.partialValue <= Self.maxBundleUncompressedSize else {
                            throw Failure.unsupported("\(base) expanded beyond Husk's unpacking limit.")
                        }
                        checksum = Self.crc32(checksum, data)
                        try out.write(contentsOf: data)
                        written = next.partialValue
                        totalWritten = bundleNext.partialValue
                    }
                    left -= UInt64(data.count)
                }
                try inflate?.finalize()
                guard written == uncompressed else { throw Failure.unsupported("\(base) did not unpack to its declared size.") }
                guard checksum == expectedCRC else { throw Failure.unsupported("\(base) failed its ZIP CRC check.") }
                if hasDescriptor {
                    let usesZip64Sizes = compressed32 == 0xffff_ffff || uncompressed32 == 0xffff_ffff ||
                        le32(lh, 18) == 0xffff_ffff || le32(lh, 22) == 0xffff_ffff ||
                        compressed > UInt64(UInt32.max) || uncompressed > UInt64(UInt32.max)
                    try validateDescriptor(file, at: dataStart + compressed, before: directoryLimit,
                                           zip64: usesZip64Sizes, crc: expectedCRC,
                                           compressed: compressed, uncompressed: uncompressed)
                }
                try out.close()
            } catch {
                try? out.close()
                throw error
            }
            names.append(isOBB ? "obb/" + base : base)
        }
        if p != cd.count {
            guard cd.count - p >= 6, le32(cd, p) == 0x0505_4b50,
                  p + 6 + Int(le16(cd, p + 4)) == cd.count else { throw Failure.notAZip }
        }
        if !names.contains(where: { $0.lowercased().hasSuffix(".apk") }) { throw Failure.unsupported("There are no APKs in that bundle.") }
        return names
    }

    private static func createOutput(at url: URL, createdFiles: inout [CreatedFile]) throws -> FileHandle {
        let descriptor = url.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw Failure.unsupported("\(url.lastPathComponent) already exists in the destination folder.")
            }
            throw posixError(errno)
        }

        var identity = stat()
        guard fstat(descriptor, &identity) == 0 else {
            let code = errno
            _ = close(descriptor)
            _ = url.path.withCString { unlink($0) }
            throw posixError(code)
        }
        createdFiles.append(CreatedFile(url: url, device: identity.st_dev, inode: identity.st_ino))
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func ensureDirectory(at url: URL, createdDirectories: inout [CreatedDirectory]) throws {
        var existing = stat()
        let found = url.path.withCString { lstat($0, &existing) }
        if found == 0 {
            guard existing.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw Failure.unsupported("The destination path \(url.path) is not a directory.")
            }
            return
        }
        guard errno == ENOENT else { throw posixError(errno) }

        let parent = url.deletingLastPathComponent()
        guard parent != url else { throw Failure.unsupported("The destination folder could not be created.") }
        try ensureDirectory(at: parent, createdDirectories: &createdDirectories)

        let result = url.path.withCString { mkdir($0, mode_t(0o700)) }
        if result == 0 {
            var identity = stat()
            guard url.path.withCString({ lstat($0, &identity) }) == 0 else {
                let code = errno
                _ = url.path.withCString { rmdir($0) }
                throw posixError(code)
            }
            createdDirectories.append(CreatedDirectory(url: url, device: identity.st_dev, inode: identity.st_ino))
            return
        }
        if errno == EEXIST {
            var raced = stat()
            guard url.path.withCString({ lstat($0, &raced) }) == 0,
                  raced.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw Failure.unsupported("The destination path \(url.path) is not a directory.")
            }
            return
        }
        throw posixError(errno)
    }

    private static func rollback(files: [CreatedFile], directories: [CreatedDirectory]) {
        for file in files.reversed() {
            var current = stat()
            guard file.url.path.withCString({ lstat($0, &current) }) == 0,
                  current.st_dev == file.device, current.st_ino == file.inode,
                  current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { continue }
            _ = file.url.path.withCString { unlink($0) }
        }
        for directory in directories.reversed() {
            var current = stat()
            guard directory.url.path.withCString({ lstat($0, &current) }) == 0,
                  current.st_dev == directory.device, current.st_ino == directory.inode,
                  current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { continue }
            // rmdir is deliberately non-recursive: never remove concurrent or pre-existing contents.
            _ = directory.url.path.withCString { rmdir($0) }
        }
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func readExactly(_ file: FileHandle, count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try file.read(upToCount: count - result.count), !chunk.isEmpty else { throw Failure.notAZip }
            result.append(chunk)
        }
        return result
    }

    private static func validateDescriptor(_ file: FileHandle, at offset: UInt64, before limit: UInt64,
                                           zip64: Bool, crc: UInt32, compressed: UInt64, uncompressed: UInt64) throws {
        guard offset <= limit, limit - offset >= 4 else { throw Failure.notAZip }
        try file.seek(toOffset: offset)
        let first = [UInt8](try readExactly(file, count: 4))
        let hasSignature = le32(first, 0) == 0x0807_4b50
        let length = UInt64((hasSignature ? 4 : 0) + 4 + (zip64 ? 16 : 8))
        guard length <= limit - offset else { throw Failure.notAZip }
        let actualCRC: UInt32
        if hasSignature {
            actualCRC = le32([UInt8](try readExactly(file, count: 4)), 0)
        } else {
            actualCRC = le32(first, 0)
        }
        let sizes = [UInt8](try readExactly(file, count: zip64 ? 16 : 8))
        let actualCompressed = zip64 ? le64(sizes, 0) : UInt64(le32(sizes, 0))
        let actualUncompressed = zip64 ? le64(sizes, 8) : UInt64(le32(sizes, 4))
        guard actualCRC == crc, actualCompressed == compressed, actualUncompressed == uncompressed else { throw Failure.notAZip }
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = ~crc
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for b in p { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return ~c
    }

    private static func le16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    private static func le64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(le32(b, o)) | UInt64(le32(b, o + 4)) << 32 }
}


