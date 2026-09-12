import Foundation
import CoreFoundation

struct LyricWord: Codable, Equatable, Sendable {
    let start: TimeInterval
    let text: String
    let end: TimeInterval?

    init(start: TimeInterval, text: String, end: TimeInterval? = nil) {
        self.start = start
        self.text = text
        self.end = end
    }
}

struct LyricLine: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let start: TimeInterval
    let text: String
    let words: [LyricWord]
    let end: TimeInterval?

    /// Always derive the fill from the audio clock so pause and backward seek are exact.
    /// A final word without an end marker is highlighted on onset, not given a made-up duration.
    func wordProgress(at time: TimeInterval) -> [Double] {
        words.enumerated().map { index, word in
            guard time.isFinite, time >= word.start else { return 0 }
            let finish = word.end ?? (index + 1 < words.count ? words[index + 1].start : end)
            guard let finish, finish > word.start else { return 1 }
            return min(1, max(0, (time - word.start) / (finish - word.start)))
        }
    }
}

struct TimedLyrics: Codable, Equatable, Sendable {
    let lines: [LyricLine]
    var isWordTimed: Bool { lines.contains { !$0.words.isEmpty } }

    func scrollLineID(at time: TimeInterval) -> Int? {
        let upper = upperBound(at: time)
        return upper > 0 ? lines[upper - 1].id : lines.first?.id
    }

    /// Recompute from the player's clock, including after backwards seeks.
    /// Equal timestamps keep original order (e.g. a lyric and its translation).
    func activeLineIDs(at time: TimeInterval) -> [Int] {
        guard time.isFinite else { return [] }
        let low = upperBound(at: time)
        guard low > 0 else { return [] }
        let start = lines[low - 1].start
        var first = low - 1
        while first > 0 && lines[first - 1].start == start { first -= 1 }
        return lines[first..<low].filter { $0.end == nil || time < $0.end! }.map(\.id)
    }

    private func upperBound(at time: TimeInterval) -> Int {
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

struct ImportedLyrics: Codable, Equatable, Sendable {
    let displayName: String
    let lyrics: TimedLyrics

    var localizedDisplayName: String { SavedMessageLocalization.text(displayName) }
}

enum LyricsError: LocalizedError {
    case tooLarge
    case tooComplex
    case unreadable
    case noTimedLines
    case invalidLine(Int)

    var errorDescription: String? {
        switch self {
        case .tooLarge: return String(localized: "The lyrics file is too large. Choose a text file no larger than 2 MB.")
        case .tooComplex: return String(localized: "The lyrics contain too many lines or word timing markers. Please check the file.")
        case .unreadable: return String(localized: "Unable to read the lyrics encoding. Use UTF-8, UTF-16, or GB18030 text.")
        case .noTimedLines: return String(localized: "No valid timestamps found. Import LRC lyrics or word-synced lyrics with [min:sec] / <min:sec> timestamps.")
        case .invalidLine(let number): return String(localized: "The timestamp on lyrics line \(number) is invalid or out of order. Please check the file.")
        }
    }
}

enum LyricsImportStore {
    static let supportedExtensions: Set<String> = ["lrc", "elrc"]
    static let maximumBytes = 2 * 1_024 * 1_024

    static func load(_ url: URL) throws -> ImportedLyrics {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw LyricsError.tooLarge }
        return ImportedLyrics(displayName: url.lastPathComponent, lyrics: try LRCParser.parse(decode(data)))
    }

    static func decode(_ data: Data) throws -> String {
        let bytes = Array(data.prefix(2))
        if bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF] {
            guard let text = String(data: data, encoding: .utf16) else { throw LyricsError.unreadable }
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        guard let text = String(data: data, encoding: gb18030) else { throw LyricsError.unreadable }
        return text
    }
}

/// LRC: [mm:ss.xx]line; Enhanced LRC: [mm:ss.xx]<mm:ss.xx>word<mm:ss.xx>.
/// Also accepts the supplied LDDC dialect: [mm:ss.xxx]word[mm:ss.xxx]word[mm:ss.xxx].
/// Word timestamps are absolute. A trailing marker supplies an explicit line end.
/// Other karaoke dialects must be added from real samples, never guessed.
enum LRCParser {
    static func parse(_ source: String) throws -> TimedLyrics {
        let rows = source.replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: .newlines)
        var parsed: [LyricLine] = []
        var offset = 0.0
        var expandedWordCount = 0
        for (index, row) in rows.enumerated() {
            var rest = row.trimmingCharacters(in: .whitespaces)[...]
            if rest.isEmpty { continue }
            if rest.lowercased().hasPrefix("[offset:") {
                guard rest.hasSuffix("]"),
                      let value = Double(rest.dropFirst(8).dropLast()), value.isFinite,
                      abs(value) <= 86_400_000 else { throw LyricsError.invalidLine(index + 1) }
                offset = value / 1_000
                continue
            }
            var starts: [Double] = []
            if rest.hasPrefix("["), rest.dropFirst().first?.isNumber == true,
               !rest.contains("]") { throw LyricsError.invalidLine(index + 1) }
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = String(rest[rest.index(after: rest.startIndex)..<close])
                guard let time = timestamp(tag) else {
                    if tag.first?.isNumber == true { throw LyricsError.invalidLine(index + 1) }
                    break // Metadata such as [ti:], [ar:], [by:].
                }
                guard starts.count < 20_000 - parsed.count else { throw LyricsError.tooComplex }
                starts.append(time)
                rest = rest[rest.index(after: close)...]
            }
            guard let firstStart = starts.first else { continue }
            let (text, words, end) = try parseWords(String(rest), lineStart: firstStart, number: index + 1)
            // Repeated line tags multiply the word list; cap the expanded result,
            // not just source bytes, before allocating copies from an imported file.
            guard starts.count <= 20_000 - parsed.count,
                  words.count <= (200_000 - expandedWordCount) / starts.count else {
                throw LyricsError.tooComplex
            }
            expandedWordCount += words.count * starts.count
            for start in starts {
                let shift = start - firstStart
                parsed.append(LyricLine(
                    id: parsed.count, start: start, text: text,
                    words: words.map { LyricWord(start: $0.start + shift, text: $0.text,
                                                end: $0.end.map { $0 + shift }) },
                    end: end.map { $0 + shift }
                ))
            }
        }
        guard parsed.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw LyricsError.noTimedLines
        }
        // Embedded file offsets are part of the imported timing; there is no adjustment UI.
        var lines: [LyricLine] = []
        for line in parsed {
            let words = line.words.map { LyricWord(start: $0.start + offset, text: $0.text,
                                                  end: $0.end.map { $0 + offset }) }
            let end = line.end.map { $0 + offset }
            lines.append(LyricLine(id: line.id, start: line.start + offset,
                                  text: line.text, words: words, end: end))
        }
        lines.sort { lhs, rhs in
            if lhs.start == rhs.start { return lhs.id < rhs.id }
            return lhs.start < rhs.start
        }
        return TimedLyrics(lines: lines)
    }

    private static func parseWords(
        _ source: String, lineStart: Double, number: Int
    ) throws -> (String, [LyricWord], Double?) {
        // Leading adjacent [time][time] tags are still repeated ordinary LRC lines.
        // Only markers interleaved with the lyric body select the square-bracket dialect.
        let square = source.contains("[") && !source.contains("<")
        let opening: Character = square ? "[" : "<"
        let closing: Character = square ? "]" : ">"
        func nextMarker(in text: Substring) -> String.Index? {
            text.indices.first { index in
                guard text[index] == opening else { return false }
                let next = text.index(after: index)
                return !square || (next < text.endIndex && text[next].isNumber)
            }
        }
        guard let firstMarker = nextMarker(in: source[...]) else { return (source, [], nil) }
        var rest = source[...]
        var words: [LyricWord] = []
        var previous = lineStart
        var end: Double?
        // Untimed prefix is displayed at the line timestamp, without inventing word timing.
        let prefix = String(rest[..<firstMarker])
        rest = rest[firstMarker...]
        if !prefix.isEmpty { words.append(LyricWord(start: lineStart, text: prefix)) }
        while !rest.isEmpty {
            guard rest.first == opening, let close = rest.firstIndex(of: closing),
                  let start = timestamp(String(rest[rest.index(after: rest.startIndex)..<close])),
                  start >= previous else { throw LyricsError.invalidLine(number) }
            previous = start
            // An empty interval between two markers is a rest. End the preceding
            // word here instead of stretching its fill across that silence.
            if let last = words.last, last.end == nil {
                words[words.count - 1] = LyricWord(start: last.start, text: last.text, end: start)
            }
            rest = rest[rest.index(after: close)...]
            let next = nextMarker(in: rest) ?? rest.endIndex
            let text = String(rest[..<next])
            rest = rest[next...]
            if text.isEmpty {
                if rest.isEmpty { end = start }
            } else {
                words.append(LyricWord(start: start, text: text))
            }
        }
        return (words.map(\.text).joined(), words, end)
    }

    private static func timestamp(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty }),
              let seconds = Double(parts.last!), seconds.isFinite, seconds >= 0, seconds < 60,
              parts.last!.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let minutes = Int(parts[parts.count - 2]), minutes >= 0,
              parts.dropLast().allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) })
        else { return nil }
        let hours = parts.count == 3 ? Int(parts[0]) : 0
        guard let hours, hours >= 0,
              parts.count == 2 || minutes < 60 else { return nil }
        return Double(hours) * 3_600 + Double(minutes) * 60 + seconds
    }
}
