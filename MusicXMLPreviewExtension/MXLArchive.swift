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
            return "The .mxl file is not a valid ZIP archive."
        case .unsupportedCompressionMethod(let method):
            return "Unsupported ZIP compression method (\(method))."
        case .decompressionFailed:
            return "Failed to decompress the MusicXML payload from the .mxl archive."
        case .rootScoreNotFound:
            return "Could not locate a root MusicXML document inside the .mxl archive."
        case .invalidXMLTextEncoding:
            return "Could not decode the MusicXML document as UTF-8 or UTF-16 text."
        }
    }
}

/// Pure-Swift in-memory MXL (ZIP + META-INF/container.xml) extractor backed by Apple's Compression framework.
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

        let normalized = rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let scoreEntry = findEntry(named: normalized) ?? findEntry(named: rootPath) else {
            throw MXLArchiveError.rootScoreNotFound
        }

        let scoreData = try extract(scoreEntry)
        return try Self.decodeXMLString(from: scoreData)
    }

    static func decodeXMLString(from data: Data) throws -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        if let utf16LE = String(data: data, encoding: .utf16LittleEndian) {
            return utf16LE
        }
        if let utf16BE = String(data: data, encoding: .utf16BigEndian) {
            return utf16BE
        }
        throw MXLArchiveError.invalidXMLTextEncoding
    }

    // MARK: - Entry Lookup

    private func findEntry(named target: String) -> ZipEntry? {
        if let exact = entries.first(where: { $0.name == target }) {
            return exact
        }
        return entries.first(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame })
    }

    private func fallbackScoreEntry() -> ZipEntry? {
        entries.first { entry in
            let lower = entry.name.lowercased()
            guard !lower.hasPrefix("meta-inf/"), !lower.hasSuffix("/") else { return false }
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
                eocdOffset = idx
                break
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
        guard elementName.lowercased() == "rootfile" else { return }
        guard let rawPath = attributeDict["full-path"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return
        }

        if firstPath == nil {
            firstPath = rawPath
        }

        let mediaType = attributeDict["media-type"]?.lowercased() ?? ""
        if preferredPath == nil && (mediaType.contains("musicxml") || rawPath.lowercased().hasSuffix(".musicxml")) {
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
