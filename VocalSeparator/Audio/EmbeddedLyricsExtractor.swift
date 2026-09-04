// Adapted from NetPlayer/NetMusic/Services/EmbeddedLyricsExtractor.swift.
// Keep the ID3 USLT/SYLT/TXXX and FLAC Vorbis-comment decoding local to the device.
import AVFoundation
import Foundation

struct EmbeddedLyricsExtractor {
    static func lyrics(in data: Data, fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "mp3":
            return ID3LyricsParser.parse(data)
        case "flac":
            return FLACLyricsParser.parse(data)
        default:
            return nil
        }
    }

    static func lyrics(from metadata: [AVMetadataItem]) async -> String? {
        for item in metadata where isLyricsMetadataItem(item) {
            if let stringValue = try? await item.load(.stringValue),
               let text = cleaned(stringValue) {
                return text
            }
            if let value = try? await item.load(.value),
               let text = cleaned(value as? String) {
                return text
            }
        }
        return nil
    }

    private static func isLyricsMetadataItem(_ item: AVMetadataItem) -> Bool {
        if let identifier = item.identifier {
            switch identifier {
            case .iTunesMetadataLyrics,
                 .id3MetadataSynchronizedLyric,
                 .id3MetadataUnsynchronizedLyric:
                return true
            default:
                if identifier.rawValue.localizedCaseInsensitiveContains("lyric") {
                    return true
                }
            }
        }

        if item.commonKey?.rawValue.localizedCaseInsensitiveContains("lyric") == true {
            return true
        }

        if let key = item.key as? String {
            let lowercasedKey = key.lowercased()
            return lowercasedKey.contains("lyric") || lowercasedKey == "\u{00a9}lyr"
        }

        return false
    }
}

private enum ID3LyricsParser {
    static func tagSize(fromHeader header: Data) -> Int? {
        guard header.count >= 10,
              header.asciiString(in: 0..<3) == "ID3" else {
            return nil
        }

        let size = synchsafeInteger(header[6], header[7], header[8], header[9])
        guard size > 0 else { return nil }
        return size + 10
    }

    static func parse(_ data: Data) -> String? {
        guard data.count >= 10,
              data.asciiString(in: 0..<3) == "ID3" else {
            return nil
        }

        let majorVersion = data[3]
        guard (majorVersion == 3 || majorVersion == 4), data[5] & 0xC0 == 0 else { return nil }
        let tagEnd = min(data.count, (tagSize(fromHeader: data) ?? data.count))
        var offset = 10
        var synchronizedLyrics: String?
        var unsynchronizedLyrics: String?
        var userDefinedLyrics: String?

        while offset + 10 <= tagEnd {
            guard let frameID = data.asciiString(in: offset..<(offset + 4)),
                  frameID.range(of: #"^[A-Z0-9]{4}$"#, options: .regularExpression) != nil else {
                break
            }

            let frameSize = majorVersion == 4
                ? synchsafeInteger(data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7])
                : bigEndianInteger(data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7])
            guard frameSize > 0 else { break }

            let frameStart = offset + 10
            let frameEnd = frameStart + frameSize
            guard frameEnd <= tagEnd else { break }

            let payload = data.subdata(in: frameStart..<frameEnd)
            let formatFlags = data[offset + 9]
            if formatFlags != 0 { offset = frameEnd; continue }
            switch frameID {
            case "SYLT":
                synchronizedLyrics = synchronizedLyrics ?? parseSYLTFrame(payload)
            case "USLT":
                unsynchronizedLyrics = unsynchronizedLyrics ?? parseUSLTFrame(payload)
            case "TXXX":
                userDefinedLyrics = userDefinedLyrics ?? parseTXXXFrame(payload)
            default:
                break
            }

            offset = frameEnd
        }

        return synchronizedLyrics ?? unsynchronizedLyrics ?? userDefinedLyrics
    }

    private static func parseUSLTFrame(_ data: Data) -> String? {
        guard data.count > 4, let encoding = data.first else { return nil }
        var offset = 1 + 3
        guard offset < data.count,
              let descriptionEnd = data.textTerminatorIndex(from: offset, encoding: encoding) else {
            return nil
        }

        offset = descriptionEnd + data.textTerminatorLength(encoding: encoding)
        guard offset < data.count else { return nil }
        return decodeText(data.subdata(in: offset..<data.count), encoding: encoding)
    }

    private static func parseSYLTFrame(_ data: Data) -> String? {
        guard data.count > 6, let encoding = data.first else { return nil }
        let timestampFormat = data[4]
        var offset = 1 + 3 + 1 + 1
        guard let descriptionEnd = data.textTerminatorIndex(from: offset, encoding: encoding) else {
            return nil
        }

        offset = descriptionEnd + data.textTerminatorLength(encoding: encoding)
        var entries: [String] = []
        var plainTextEntries: [String] = []

        while offset < data.count {
            guard let textEnd = data.textTerminatorIndex(from: offset, encoding: encoding) else {
                break
            }

            let textData = data.subdata(in: offset..<textEnd)
            let text = decodeText(textData, encoding: encoding)
            offset = textEnd + data.textTerminatorLength(encoding: encoding)

            guard offset + 4 <= data.count else { break }
            let timestamp = bigEndianInteger(data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
            offset += 4

            guard let text, !text.isEmpty else { continue }
            plainTextEntries.append(text)
            if timestampFormat == 2 {
                entries.append("\(lrcTimestamp(milliseconds: timestamp))\(text)")
            }
        }

        if !entries.isEmpty {
            return entries.joined(separator: "\n")
        }

        let plainText = plainTextEntries.joined(separator: "\n")
        return cleaned(plainText)
    }

    private static func parseTXXXFrame(_ data: Data) -> String? {
        guard data.count > 1, let encoding = data.first else { return nil }
        let offset = 1
        guard let descriptionEnd = data.textTerminatorIndex(from: offset, encoding: encoding) else {
            return nil
        }

        let description = decodeText(data.subdata(in: offset..<descriptionEnd), encoding: encoding)?
            .uppercased()
        let valueStart = descriptionEnd + data.textTerminatorLength(encoding: encoding)
        guard valueStart < data.count,
              let description,
              ["LYRICS", "SYNCEDLYRICS", "UNSYNCEDLYRICS"].contains(description) else {
            return nil
        }

        return decodeText(data.subdata(in: valueStart..<data.count), encoding: encoding)
    }

    private static func decodeText(_ data: Data, encoding: UInt8) -> String? {
        let string: String?
        switch encoding {
        case 0:
            string = decodeLegacyEncodedText(data)
        case 1:
            string = String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .utf16LittleEndian)
                ?? String(data: data, encoding: .utf16BigEndian)
        case 2:
            string = String(data: data, encoding: .utf16BigEndian)
        case 3:
            string = String(data: data, encoding: .utf8)
        default:
            string = String(data: data, encoding: .utf8)
        }

        return cleaned(string)
    }

    private static func decodeLegacyEncodedText(_ data: Data) -> String? {
        let latin1 = cleaned(String(data: data, encoding: .isoLatin1))
        guard data.contains(where: { $0 >= 0x80 }) else {
            return latin1
        }

        if let utf8 = cleaned(String(data: data, encoding: .utf8)),
           shouldPreferCJKDecodedText(utf8, over: latin1) {
            return utf8
        }

        if let gb18030 = cleaned(String(data: data, encoding: gb18030Encoding)),
           shouldPreferCJKDecodedText(gb18030, over: latin1) {
            return gb18030
        }

        return latin1
    }

    private static var gb18030Encoding: String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
    }

    private static func shouldPreferCJKDecodedText(_ decoded: String, over latin1: String?) -> Bool {
        let decodedCJKCount = cjkScalarCount(in: decoded)
        guard decodedCJKCount > 0 else { return false }
        guard let latin1 else { return true }
        return cjkScalarCount(in: latin1) == 0 &&
            highLatin1ScalarCount(in: latin1) >= decodedCJKCount
    }

    private static func cjkScalarCount(in value: String) -> Int {
        value.unicodeScalars.reduce(0) { count, scalar in
            count + (isCJKScalar(scalar) ? 1 : 0)
        }
    }

    private static func highLatin1ScalarCount(in value: String) -> Int {
        value.unicodeScalars.reduce(0) { count, scalar in
            count + ((0x00A0...0x00FF).contains(scalar.value) ? 1 : 0)
        }
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF:
            return true
        default:
            return false
        }
    }

    private static func synchsafeInteger(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        (Int(a & 0x7F) << 21) |
            (Int(b & 0x7F) << 14) |
            (Int(c & 0x7F) << 7) |
            Int(d & 0x7F)
    }
}

private enum FLACLyricsParser {
    static func parse(_ data: Data) -> String? {
        guard let start = flacStart(in: data) else { return nil }

        var offset = start + 4
        var lyrics: String?
        var syncedLyrics: String?
        var unsyncedLyrics: String?
        var isLastBlock = false

        while !isLastBlock, offset + 4 <= data.count {
            let blockHeader = data[offset]
            isLastBlock = (blockHeader & 0x80) != 0
            let blockType = blockHeader & 0x7F
            let blockLength = (Int(data[offset + 1]) << 16) |
                (Int(data[offset + 2]) << 8) |
                Int(data[offset + 3])
            let blockStart = offset + 4
            let blockEnd = blockStart + blockLength
            guard blockLength >= 0, blockEnd <= data.count else { break }

            if blockType == 4 {
                let comments = parseVorbisComments(data.subdata(in: blockStart..<blockEnd))
                lyrics = lyrics ?? comments["LYRICS"]
                syncedLyrics = syncedLyrics ?? comments["SYNCEDLYRICS"]
                unsyncedLyrics = unsyncedLyrics ?? comments["UNSYNCEDLYRICS"]
            }

            offset = blockEnd
        }

        return syncedLyrics ?? lyrics ?? unsyncedLyrics
    }

    private static func flacStart(in data: Data) -> Int? {
        if data.count >= 4, data.asciiString(in: 0..<4) == "fLaC" {
            return 0
        }

        if let id3Size = ID3LyricsParser.tagSize(fromHeader: data),
           data.count >= id3Size + 4,
           data.asciiString(in: id3Size..<(id3Size + 4)) == "fLaC" {
            return id3Size
        }

        return nil
    }

    private static func parseVorbisComments(_ data: Data) -> [String: String] {
        var offset = 0
        guard let vendorLength = data.readUInt32LE(at: offset) else { return [:] }
        offset += 4 + Int(vendorLength)
        guard let commentCount = data.readUInt32LE(at: offset) else { return [:] }
        offset += 4

        var comments: [String: String] = [:]
        for _ in 0..<commentCount {
            guard let length = data.readUInt32LE(at: offset) else { break }
            offset += 4
            let end = offset + Int(length)
            guard end <= data.count else { break }

            if let comment = String(data: data.subdata(in: offset..<end), encoding: .utf8),
               let separator = comment.firstIndex(of: "=") {
                let key = String(comment[..<separator]).uppercased()
                let value = String(comment[comment.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, comments[key] == nil {
                    comments[key] = value
                }
            }
            offset = end
        }

        return comments
    }
}

private func cleaned(_ value: String?) -> String? {
    guard let value else { return nil }
    let cleaned = value
        .replacingOccurrences(of: "\0", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : cleaned
}

private func bigEndianInteger(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
    (Int(a) << 24) | (Int(b) << 16) | (Int(c) << 8) | Int(d)
}

private func lrcTimestamp(milliseconds: Int) -> String {
    let centiseconds = max(0, milliseconds) / 10
    let minutes = centiseconds / 6000
    let seconds = (centiseconds / 100) % 60
    let remainder = centiseconds % 100
    return String(format: "[%02d:%02d.%02d]", minutes, seconds, remainder)
}

private extension Data {
    func asciiString(in range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= count else { return nil }
        return String(data: subdata(in: range), encoding: .ascii)
    }

    func firstIndex(of byte: UInt8, from start: Int) -> Int? {
        guard start < count else { return nil }
        for index in start..<count where self[index] == byte {
            return index
        }
        return nil
    }

    func textTerminatorIndex(from start: Int, encoding: UInt8) -> Int? {
        guard start < count else { return nil }
        if encoding == 1 || encoding == 2 {
            var index = start
            while index + 1 < count {
                if self[index] == 0, self[index + 1] == 0 {
                    return index
                }
                index += 2
            }
            return nil
        }

        return firstIndex(of: 0, from: start)
    }

    func textTerminatorLength(encoding: UInt8) -> Int {
        encoding == 1 || encoding == 2 ? 2 : 1
    }

    func readUInt32LE(at offset: Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        return UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}
