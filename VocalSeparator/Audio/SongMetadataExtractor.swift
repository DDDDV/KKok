import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ExtractedSongMetadata: Sendable {
    var artworkData: Data?
    var embeddedLyrics: String?
    var didReadMetadata = false
}

/// Persist only the thumbnail's relative filename, not image bytes in library.json.
struct SongMetadata: Codable, Equatable, Sendable {
    var artworkFileName: String?
    var embeddedLyrics: String?
    var didReadMetadata: Bool
    var hasTimedLyrics: Bool
}

protocol SongMetadataExtracting: Sendable {
    func extract(from url: URL) async -> ExtractedSongMetadata
}

struct SongMetadataExtractor: SongMetadataExtracting {
    static let maximumTagBytes = 12 * 1_024 * 1_024

    func extract(from url: URL) async -> ExtractedSongMetadata {
        var result = ExtractedSongMetadata()
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { return result }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: Self.maximumTagBytes) else { return result }

        // Follow NetPlayer's format-specific parsing, then use system metadata for
        // containers such as M4A/MP4, WAV and AIFF. Detect tags by bytes, not filename.
        let flacStart = EmbeddedArtworkParser.flacStart(in: header)
        let format = flacStart != nil ? "flac" : (header.starts(with: Data("ID3".utf8)) ? "mp3" : "")
        result.embeddedLyrics = EmbeddedLyricsExtractor.lyrics(in: header, fileExtension: format)
        result.artworkData = EmbeddedArtworkParser.artwork(in: header)
        result.didReadMetadata = !format.isEmpty

        let asset = AVURLAsset(url: url)
        if let metadata = try? await asset.load(.metadata) {
            result.didReadMetadata = true
            if result.embeddedLyrics == nil {
                result.embeddedLyrics = await EmbeddedLyricsExtractor.lyrics(from: metadata)
            }
            if result.artworkData == nil {
                result.artworkData = await artwork(from: metadata)
            }
        }
        if result.artworkData == nil, let common = try? await asset.load(.commonMetadata) {
            result.artworkData = await artwork(from: common)
        }
        if let text = result.embeddedLyrics, text.utf8.count > LyricsImportStore.maximumBytes {
            result.embeddedLyrics = nil
            result.didReadMetadata = false
        }
        result.artworkData = result.artworkData.flatMap(Self.thumbnail)
        return result
    }

    private func artwork(from items: [AVMetadataItem]) async -> Data? {
        for item in items where item.commonKey == .commonKeyArtwork ||
            item.identifier == .iTunesMetadataCoverArt || item.identifier == .id3MetadataAttachedPicture {
            if let data = try? await item.load(.dataValue), Self.thumbnail(data) != nil { return data }
        }
        return nil
    }

    /// ImageIO downsamples before decoding, so large covers do not become full-size UI bitmaps.
    static func thumbnail(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maximumTagBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// Adapted from NetPlayer's ID3MetadataParser/APIC and VorbisCommentParser/PICTURE.
enum EmbeddedArtworkParser {
    static func artwork(in data: Data) -> Data? {
        if let start = flacStart(in: data) { return flacArtwork(data, start: start) }
        guard let tagSize = id3Size(data), data.count >= 10,
              (data[3] == 3 || data[3] == 4), data[5] & 0xC0 == 0 else { return nil }
        var offset = 10
        let end = min(tagSize, data.count)
        var fallback: Data?
        while offset + 10 <= end {
            let size = integer(data, at: offset + 4, synchsafe: data[3] == 4)
            let next = offset + 10 + size
            guard size > 0, next <= end else { break }
            if String(data: data.subdata(in: offset..<offset + 4), encoding: .ascii) == "APIC",
               data[offset + 9] == 0,
               let picture = apic(data.subdata(in: offset + 10..<next)),
               SongMetadataExtractor.thumbnail(picture.data) != nil {
                if picture.isFront { return picture.data }
                fallback = fallback ?? picture.data
            }
            offset = next
        }
        return fallback
    }

    static func flacStart(in data: Data) -> Int? {
        if data.starts(with: Data("fLaC".utf8)) { return 0 }
        if let offset = id3Size(data), offset + 4 <= data.count,
           data.subdata(in: offset..<offset + 4) == Data("fLaC".utf8) { return offset }
        return nil
    }

    private static func id3Size(_ data: Data) -> Int? {
        guard data.count >= 10, data.starts(with: Data("ID3".utf8)),
              data[6..<10].allSatisfy({ $0 < 128 }) else { return nil }
        return 10 + integer(data, at: 6, synchsafe: true)
    }

    private static func integer(_ data: Data, at offset: Int, synchsafe: Bool = false) -> Int {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data[offset..<offset + 4].reduce(0) { ($0 << (synchsafe ? 7 : 8)) | Int($1 & (synchsafe ? 0x7F : 0xFF)) }
    }

    private static func apic(_ data: Data) -> (data: Data, isFront: Bool)? {
        guard data.count > 4, let mimeEnd = data.dropFirst().firstIndex(of: 0), mimeEnd + 2 < data.count else { return nil }
        let front = data[mimeEnd + 1] == 3
        let width = (data[0] == 1 || data[0] == 2) ? 2 : 1
        var offset = mimeEnd + 2
        while offset + width <= data.count {
            if data[offset..<offset + width].allSatisfy({ $0 == 0 }) {
                offset += width
                guard offset < data.count else { return nil }
                return (data.subdata(in: offset..<data.count), front)
            }
            offset += width
        }
        return nil
    }

    private static func flacArtwork(_ data: Data, start: Int) -> Data? {
        var offset = start + 4
        var fallback: Data?
        while offset + 4 <= data.count {
            let type = data[offset] & 0x7F
            let last = data[offset] & 0x80 != 0
            let size = (Int(data[offset + 1]) << 16) | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
            let next = offset + 4 + size
            guard next <= data.count else { break }
            if type == 6, let picture = flacPicture(data.subdata(in: offset + 4..<next)),
               SongMetadataExtractor.thumbnail(picture.data) != nil {
                if picture.isFront { return picture.data }
                fallback = fallback ?? picture.data
            }
            if last { break }
            offset = next
        }
        return fallback
    }

    private static func flacPicture(_ data: Data) -> (data: Data, isFront: Bool)? {
        guard data.count >= 32 else { return nil }
        let front = integer(data, at: 0) == 3
        let mimeEnd = 8 + integer(data, at: 4)
        guard mimeEnd + 4 <= data.count,
              String(data: data.subdata(in: 8..<mimeEnd), encoding: .utf8)?.hasPrefix("image/") == true else { return nil }
        let sizeOffset = mimeEnd + 4 + integer(data, at: mimeEnd) + 16
        guard sizeOffset + 4 <= data.count else { return nil }
        let start = sizeOffset + 4
        let end = start + integer(data, at: sizeOffset)
        guard end > start, end <= data.count else { return nil }
        return (data.subdata(in: start..<end), front)
    }
}
