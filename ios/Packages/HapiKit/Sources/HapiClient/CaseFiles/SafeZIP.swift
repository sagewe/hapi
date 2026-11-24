import Foundation
import CoreFoundation
import CZlib

public enum SafeZIPError: LocalizedError, Equatable {
    case invalid, unsafePath, encrypted, tooLarge, unsupported, checksum
    public var errorDescription: String? {
        switch self {
        case .invalid: "压缩包已损坏或目录不完整"
        case .unsafePath: "压缩包包含不安全路径，无法展开"
        case .encrypted: "这是加密 ZIP，请先提供未加密副本"
        case .tooLarge: "压缩包展开后过大，请分批提供资料"
        case .unsupported: "暂不支持此 ZIP 格式，请提供标准 ZIP 副本"
        case .checksum: "文件校验失败，请重新提供压缩包"
        }
    }
}

/// Reads the directory in memory. Extracts only an explicitly chosen regular
/// file into caller-owned storage; never interprets an archive path on disk.
public struct SafeZIP: Sendable {
    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: Int
        public let path: String
        public let size: Int
        let compressed: Int
        let method: UInt16
        let crc: UInt32
        let offset: Int
        public var fileName: String { (path as NSString).lastPathComponent }
        public var isImage: Bool { ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains((fileName as NSString).pathExtension.lowercased()) }
    }
    public let entries: [Entry]
    private let bytes: Data
    private let directoryOffset: Int
    public static let maxFileBytes = 50 * 1024 * 1024
    public static let maxTotalBytes = 250 * 1024 * 1024

    public static func validatePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { throw SafeZIPError.unsafePath }
    }
    public init(data: Data) throws {
        guard data.count >= 22 else { throw SafeZIPError.invalid }
        guard data.count <= Self.maxTotalBytes else { throw SafeZIPError.tooLarge }
        let b = Data(data); bytes = b
        let lower = max(0, b.count - 65557)
        guard let end = stride(from: b.count - 22, through: lower, by: -1).first(where: {
            b.u32($0) == 0x06054b50 && $0 + 22 + Int(b.u16($0 + 20)) == b.count
        }) else { throw SafeZIPError.invalid }
        guard b.u16(end + 4) == 0, b.u16(end + 6) == 0, b.u16(end + 8) == b.u16(end + 10) else { throw SafeZIPError.unsupported }
        let count = Int(b.u16(end + 10)), length = Int(b.u32(end + 12)), start = Int(b.u32(end + 16))
        guard count < 65535, start != Int(UInt32.max), length != Int(UInt32.max) else { throw SafeZIPError.unsupported }
        guard count <= 2000, start + length == end else { throw SafeZIPError.invalid }
        directoryOffset = start
        var cursor = start, total = 0, result: [Entry] = [], names = Set<String>()
        for index in 0..<count {
            guard cursor >= 0, cursor + 46 <= end, b.u32(cursor) == 0x02014b50 else { throw SafeZIPError.invalid }
            let flags = b.u16(cursor + 8), method = b.u16(cursor + 10)
            if flags & 1 != 0 || flags & 0x40 != 0 { throw SafeZIPError.encrypted }
            guard method == 0 || method == 8 else { throw SafeZIPError.unsupported }
            let packed = Int(b.u32(cursor + 20)), size = Int(b.u32(cursor + 24))
            let nameLength = Int(b.u16(cursor + 28)), extra = Int(b.u16(cursor + 30)), comment = Int(b.u16(cursor + 32))
            let next = cursor + 46 + nameLength + extra + comment
            guard next <= end, b.u16(cursor + 34) == 0 else { throw SafeZIPError.invalid }
            let nameBytes = b.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard let name = String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))) else { throw SafeZIPError.invalid }
            try Self.validatePath(name)
            let mode = (b.u32(cursor + 38) >> 16) & 0xf000
            guard mode != 0xa000, mode == 0 || mode == 0x8000 || mode == 0x4000 else { throw SafeZIPError.unsafePath }
            total += size
            guard size <= Self.maxFileBytes, total <= Self.maxTotalBytes, size <= max(1, packed) * 200 else { throw SafeZIPError.tooLarge }
            guard names.insert(name).inserted else { throw SafeZIPError.invalid }
            let offset = Int(b.u32(cursor + 42))
            guard offset + 30 <= start else { throw SafeZIPError.invalid }
            if !name.hasSuffix("/"), !name.split(separator: "/").contains("__MACOSX"), (name as NSString).lastPathComponent != ".DS_Store" {
                result.append(Entry(id: index, path: name, size: size, compressed: packed, method: method, crc: b.u32(cursor + 16), offset: offset))
            }
            cursor = next
        }
        guard cursor == end else { throw SafeZIPError.invalid }
        entries = result
    }
    public func extract(_ entry: Entry) throws -> Data {
        guard entries.contains(entry) else { throw SafeZIPError.invalid }
        let p = entry.offset, b = bytes
        guard b.u32(p) == 0x04034b50, b.u16(p + 6) & 0x41 == 0, b.u16(p + 8) == entry.method else { throw SafeZIPError.invalid }
        let nameLength = Int(b.u16(p + 26)), extra = Int(b.u16(p + 28)), start = p + 30 + nameLength + extra
        guard start <= directoryOffset, start + entry.compressed <= directoryOffset else { throw SafeZIPError.invalid }
        let localName = b.subdata(in: p + 30..<p + 30 + nameLength)
        guard (String(data: localName, encoding: .utf8) ?? String(data: localName, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))))) == entry.path else { throw SafeZIPError.invalid }
        let input = b.subdata(in: start..<start + entry.compressed)
        var output: Data
        if entry.method == 0 {
            guard input.count == entry.size else { throw SafeZIPError.invalid }; output = input
        } else {
            output = Data(count: max(1, entry.size))
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw SafeZIPError.invalid }
            defer { inflateEnd(&stream) }
            let status = input.withUnsafeBytes { src in
                output.withUnsafeMutableBytes { dst in
                    stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(input.count)
                    stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(dst.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.size, stream.total_in == input.count else { throw SafeZIPError.invalid }
            output.count = entry.size
        }
        guard Self.crc(output) == entry.crc else { throw SafeZIPError.checksum }
        return output
    }
    private static func crc(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
    }
    /// Standard UTF-8 ZIP, stored entries, no dependencies or subprocesses.
    /// Duplicate basenames are renamed, so every selected document survives.
    public static func pack(_ files: [(name: String, data: Data)]) throws -> Data {
        guard files.count <= 2000 else { throw SafeZIPError.tooLarge }
        var body = Data(), central = Data(), used = Set<String>(), total = 0
        for file in files {
            try validatePath(file.name)
            var name = (file.name as NSString).lastPathComponent
            if name.isEmpty || name == "." { throw SafeZIPError.unsafePath }
            let original = name; var n = 1
            while !used.insert(name.lowercased()).inserted {
                n += 1; let ext = (original as NSString).pathExtension
                name = "\((original as NSString).deletingPathExtension) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            }
            let nameBytes = Data(name.utf8), size = file.data.count
            total += size
            guard size <= maxFileBytes, total <= maxTotalBytes, nameBytes.count <= 255 else { throw SafeZIPError.tooLarge }
            let offset = body.count, crc = crc(file.data)
            body.le32(0x04034b50); body.le16(20); body.le16(0x800); body.le16(0); body.le16(0); body.le16(0x21)
            body.le32(crc); body.le32(UInt32(size)); body.le32(UInt32(size)); body.le16(UInt16(nameBytes.count)); body.le16(0)
            body.append(nameBytes); body.append(file.data)
            central.le32(0x02014b50); central.le16(20); central.le16(20); central.le16(0x800); central.le16(0)
            central.le16(0); central.le16(0x21); central.le32(crc); central.le32(UInt32(size)); central.le32(UInt32(size))
            central.le16(UInt16(nameBytes.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0); central.le32(0); central.le32(UInt32(offset)); central.append(nameBytes)
        }
        let start = body.count; body.append(central)
        body.le32(0x06054b50); body.le16(0); body.le16(0); body.le16(UInt16(files.count)); body.le16(UInt16(files.count))
        body.le32(UInt32(central.count)); body.le32(UInt32(start)); body.le16(0)
        return body
    }
}
private extension Data {
    func u16(_ p: Int) -> UInt16 { UInt16(self[p]) | UInt16(self[p+1]) << 8 }
    func u32(_ p: Int) -> UInt32 { UInt32(u16(p)) | UInt32(u16(p+2)) << 16 }
    mutating func le16(_ v: UInt16) { append(UInt8(v & 255)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 65535)); le16(UInt16(v >> 16)) }
}
