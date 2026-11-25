import Compression
import Foundation

enum MXLArchiveError: LocalizedError {
    case invalidArchive
    case unsupportedCompressionMethod(UInt16)
    case decompressionFailed
    case rootScoreNotFound
    case invalidXMLTextEncoding

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "The archive is not a valid ZIP file."
        case .unsupportedCompressionMethod(let method):
            return "Unsupported ZIP compression method (\(method))."
        case .decompressionFailed:
            return "Failed to decompress the MusicXML payload from the archive."
        case .rootScoreNotFound:
            return "Could not locate a root MusicXML document inside the .mxl archive."
        case .invalidXMLTextEncoding:
            return "Could not decode the MusicXML document text encoding."
        }
    }
}

/// Pure-Swift in-memory ZIP extractor for `.mxl` and `.mscz` archives backed by Apple's Compression framework.
struct MXLArchive {
    private struct ZipEntry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private let entries: [ZipEntry]

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.parseCentralDirectory(in: data)
    }

    init(url: URL) throws {
        let raw = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(data: raw)
    }

    /// Extracts the primary MusicXML string identified by `META-INF/container.xml`.
    func extractRootMusicXML() throws -> String {
        let rootPath: String
        if let containerEntry = findEntry(named: "META-INF/container.xml") {
            let containerData = try extract(containerEntry)
            let parser = ContainerXMLParser(data: containerData)
            if let parsedPath = parser.parseRootFilePath() {
                rootPath = parsedPath
            } else if let fallback = fallbackScoreEntry() {
                rootPath = fallback.name
            } else {
                throw MXLArchiveError.rootScoreNotFound
            }
        } else if let fallback = fallbackScoreEntry() {
            rootPath = fallback.name
        } else {
            throw MXLArchiveError.rootScoreNotFound
        }

        guard let scoreEntry = findEntry(named: rootPath) else {
            throw MXLArchiveError.rootScoreNotFound
        }

        let scoreData = try extract(scoreEntry)
        return try Self.decodeXMLString(from: scoreData)
    }

    /// Extracts an arbitrary archive entry by path (normalized + case-insensitive fallback), or returns `nil` if absent.
    func extractEntry(named target: String) throws -> Data? {
        guard let entry = findEntry(named: target) else {
            return nil
        }
        return try extract(entry)
    }

    /// Extracts the embedded preview PNG (`Thumbnails/thumbnail.png`) from a MuseScore `.mscz` archive.
    func extractMuseScoreThumbnail() throws -> Data? {
        if let exact = try extractEntry(named: "Thumbnails/thumbnail.png") {
            return exact
        }
        if let fallback = entries.first(where: { entry in
            let lower = entry.name.lowercased()
            return (lower.hasPrefix("thumbnails/") || lower == "thumbnail.png") && lower.hasSuffix(".png")
        }) {
            return try extract(fallback)
        }
        return nil
    }

    static func decodeXMLString(from data: Data) throws -> String {
        guard !data.isEmpty else { throw MXLArchiveError.invalidXMLTextEncoding }

        // 1. Explicit BOM checks (avoid decoding BOM-less Latin-1 as UTF-16 mojibake).
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            if let utf8 = String(data: data.dropFirst(3), encoding: .utf8) {
                return utf8
            }
        }
        if data.count >= 2 {
            if data[0] == 0xFF, data[1] == 0xFE, let utf16LE = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
                return utf16LE
            }
            if data[0] == 0xFE, data[1] == 0xFF, let utf16BE = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
                return utf16BE
            }
        }

        // 2. UTF-8 (standard MusicXML encoding).
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        // 3. BOM-less UTF-16 heuristic (only when NUL bytes indicate 16-bit ASCII characters).
        let sample = data.prefix(64)
        if sample.contains(0) {
            if let utf16LE = String(data: data, encoding: .utf16LittleEndian), utf16LE.contains("<") {
                return utf16LE
            }
            if let utf16BE = String(data: data, encoding: .utf16BigEndian), utf16BE.contains("<") {
                return utf16BE
            }
        }

        // 4. Single-byte legacy MusicXML encodings (ISO-8859-1 / Windows-1252).
        if let cp1252 = String(data: data, encoding: .windowsCP1252) {
            return cp1252
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }

        throw MXLArchiveError.invalidXMLTextEncoding
    }

    // MARK: - Entry Lookup

    private static func normalizePath(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\\", with: "/")
        while s.hasPrefix("./") {
            s.removeFirst(2)
        }
        while s.hasPrefix("/") {
            s.removeFirst()
        }
        return s
    }

    private func findEntry(named target: String) -> ZipEntry? {
        let candidates = [
            target,
            Self.normalizePath(target),
            Self.normalizePath(target.removingPercentEncoding ?? target),
        ]

        for candidate in candidates {
            if let exact = entries.first(where: { $0.name == candidate }) {
                return exact
            }
        }
        for candidate in candidates {
            if let ci = entries.first(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return ci
            }
        }
        return nil
    }

    private func fallbackScoreEntry() -> ZipEntry? {
        entries.first { entry in
            let lower = entry.name.lowercased()
            guard !lower.hasPrefix("meta-inf/"),
                  !lower.hasPrefix("__macosx/"),
                  !lower.hasSuffix("/") else {
                return false
            }
            return lower.hasSuffix(".musicxml") || lower.hasSuffix(".xml")
        }
    }

    // MARK: - ZIP Parsing & Decompression

    private static func parseCentralDirectory(in data: Data) throws -> [ZipEntry] {
        guard data.count >= 22 else { throw MXLArchiveError.invalidArchive }

        let searchLimit = max(0, data.count - (65_535 + 22))
        var eocdOffset: Int?
        var idx = data.count - 22
        while idx >= searchLimit {
            if data.readUInt32LE(at: idx) == 0x0605_4b50 {
                let commentLen = Int(data.readUInt16LE(at: idx + 20))
                if idx + 22 + commentLen == data.count {
                    eocdOffset = idx
                    break
                }
            }
            idx -= 1
        }

        guard let eocd = eocdOffset else { throw MXLArchiveError.invalidArchive }
        let entryCount = Int(data.readUInt16LE(at: eocd + 10))
        let centralDirOffset = Int(data.readUInt32LE(at: eocd + 16))
        guard centralDirOffset >= 0, centralDirOffset < data.count else {
            throw MXLArchiveError.invalidArchive
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(entryCount)

        var cursor = centralDirOffset
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count, data.readUInt32LE(at: cursor) == 0x0201_4b50 else {
                throw MXLArchiveError.invalidArchive
            }

            let method = data.readUInt16LE(at: cursor + 10)
            let compressedSize = Int(data.readUInt32LE(at: cursor + 20))
            let uncompressedSize = Int(data.readUInt32LE(at: cursor + 24))
            let nameLen = Int(data.readUInt16LE(at: cursor + 28))
            let extraLen = Int(data.readUInt16LE(at: cursor + 30))
            let commentLen = Int(data.readUInt16LE(at: cursor + 32))
            let localOffset = Int(data.readUInt32LE(at: cursor + 42))

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= data.count else { throw MXLArchiveError.invalidArchive }

            let nameData = data.subdata(in: nameStart..<nameEnd)
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""

            entries.append(
                ZipEntry(
                    name: name,
                    compressionMethod: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localOffset
                )
            )

            cursor = nameEnd + extraLen + commentLen
        }

        return entries
    }

    private func extract(_ entry: ZipEntry) throws -> Data {
        let localOffset = entry.localHeaderOffset
        guard localOffset + 30 <= data.count, data.readUInt32LE(at: localOffset) == 0x0403_4b50 else {
            throw MXLArchiveError.invalidArchive
        }

        let localNameLen = Int(data.readUInt16LE(at: localOffset + 26))
        let localExtraLen = Int(data.readUInt16LE(at: localOffset + 28))
        let payloadStart = localOffset + 30 + localNameLen + localExtraLen
        let payloadEnd = payloadStart + entry.compressedSize
        guard payloadStart >= 0, payloadEnd <= data.count else {
            throw MXLArchiveError.invalidArchive
        }

        let payload = data.subdata(in: payloadStart..<payloadEnd)
        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            return try Self.decompressDeflate(payload, expectedSize: entry.uncompressedSize)
        default:
            throw MXLArchiveError.unsupportedCompressionMethod(entry.compressionMethod)
        }
    }

    private static func decompressDeflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        if compressed.isEmpty {
            return Data()
        }

        let chunkSize = max(expectedSize, 64 * 1024)
        var output = Data()
        output.reserveCapacity(chunkSize)

        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dstBuffer.deallocate() }

        return try compressed.withUnsafeBytes { rawSrc -> Data in
            guard let srcBase = rawSrc.bindMemory(to: UInt8.self).baseAddress else {
                return Data()
            }

            var stream = compression_stream(
                dst_ptr: dstBuffer,
                dst_size: chunkSize,
                src_ptr: srcBase,
                src_size: compressed.count,
                state: nil
            )

            let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            guard initStatus == COMPRESSION_STATUS_OK else {
                throw MXLArchiveError.decompressionFailed
            }
            defer { compression_stream_destroy(&stream) }

            stream.src_ptr = srcBase
            stream.src_size = compressed.count
            stream.dst_ptr = dstBuffer
            stream.dst_size = chunkSize

            while true {
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.dst_size
                if produced > 0 {
                    output.append(dstBuffer, count: produced)
                }

                switch status {
                case COMPRESSION_STATUS_OK:
                    stream.dst_ptr = dstBuffer
                    stream.dst_size = chunkSize
                case COMPRESSION_STATUS_END:
                    return output
                default:
                    throw MXLArchiveError.decompressionFailed
                }
            }
        }
    }
}

// MARK: - META-INF/container.xml Parser

private final class ContainerXMLParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var preferredPath: String?
    private var firstPath: String?

    init(data: Data) {
        self.parser = XMLParser(data: data)
        super.init()
        self.parser.delegate = self
    }

    func parseRootFilePath() -> String? {
        parser.parse()
        return preferredPath ?? firstPath
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let lowerName = elementName.lowercased()
        guard lowerName == "rootfile" || lowerName.hasSuffix(":rootfile") else { return }
        guard let rawPath = attributeDict["full-path"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return
        }

        let mediaType = attributeDict["media-type"]?.lowercased() ?? ""
        let lowerPath = rawPath.lowercased()
        let isMusicXML = mediaType.contains("musicxml")
            || lowerPath.hasSuffix(".musicxml")
            || lowerPath.hasSuffix(".xml")

        if firstPath == nil {
            firstPath = rawPath
        }
        if preferredPath == nil && isMusicXML {
            preferredPath = rawPath
        }
    }
}

// MARK: - Little-Endian Helpers

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
