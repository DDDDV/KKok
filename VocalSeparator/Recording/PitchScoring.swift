import Foundation

struct PitchPhraseScore: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let text: String
    let start: Double
    let score: Int?
}

struct PitchScoreReport: Codable, Equatable, Sendable {
    let score: Int?
    let matchedPercent: Int
    let voicedPercent: Int
    let referenceSeconds: Double
    let recordedDuration: Double
    let songDuration: Double
    let phrases: [PitchPhraseScore]
    let unavailableReason: String?
    // Version the scoring rules with the saved result; effects never recalculate dry-voice scores.
    let version: Int

    var assessment: String {
        guard let score else { return "暂未评分" }
        switch score {
        case 90...100: return "音准出色"
        case 75..<90: return "唱得很稳"
        case 60..<75: return "继续练习"
        default: return "跟着旋律再试一次"
        }
    }
}

struct PitchScoringContext: Codable, Sendable {
    let reference: PitchReference?
    let unavailableReason: String?
}

/// Fixed song-clock comparison, without unrestricted time warping or octave folding.
/// Silence on a valid reference is a miss; missing/uncertain reference is excluded.
struct PitchScorer {
    private let reference: [PitchFrame]
    private let songDuration: Double
    private var observations: [Int: PitchFrame] = [:]

    init(reference: PitchReference) {
        self.reference = reference.scorableFrames
        songDuration = reference.duration
    }

    mutating func append(_ frames: [PitchFrame]) {
        for frame in frames where frame.time.isFinite && frame.time >= 0 && frame.time <= songDuration {
            observations[Self.key(frame.time)] = frame
        }
    }

    private static func key(_ time: Double) -> Int { Int((time / PitchDetector.step).rounded()) }

    private func statistics(from start: Double, to end: Double) -> (score: Int?, matched: Int, voiced: Int, seconds: Double) {
        var total = 0, matched = 0, voiced = 0
        var points = 0.0
        for target in reference {
            if target.time >= end { break }
            guard target.time >= start else { continue }
            guard let expected = target.reliableMidi else { continue }
            total += 1
            guard let actual = observations[Self.key(target.time)]?.reliableMidi else { continue }
            voiced += 1
            let cents = abs(actual - expected) * 100
            if cents <= 50 { matched += 1 }
            // 25-cent full-credit band; fades to zero at one semitone.
            points += max(0, min(1, (100 - cents) / 75))
        }
        let seconds = Double(total) * PitchDetector.step
        guard total > 0 else { return (nil, 0, 0, 0) }
        return (seconds >= 0.3 ? Int((100 * points / Double(total)).rounded()) : nil,
                Int((100 * Double(matched) / Double(total)).rounded()),
                Int((100 * Double(voiced) / Double(total)).rounded()), seconds)
    }

    func report(until time: Double, lyrics: TimedLyrics?, unavailableReason: String? = nil) -> PitchScoreReport {
        let end = min(songDuration, max(0, time.isFinite ? time : 0))
        // Only complete centred analysis windows can be judged at an early stop.
        let comparisonEnd = max(0, end - Double(PitchDetector.window) / (2 * PitchDetector.sampleRate))
        let stats = statistics(from: 0, to: comparisonEnd)
        let reason = unavailableReason ?? (stats.seconds < 1 ? "有效参考旋律不足 1 秒，暂不能评分" : nil)
        let lines = lyrics?.lines ?? []
        let phrases = lines.enumerated().compactMap { index, line -> PitchPhraseScore? in
            guard line.start < end else { return nil }
            let nextStart = lines.dropFirst(index + 1).first { $0.start > line.start }?.start ?? songDuration
            let finish = min(comparisonEnd, line.end ?? nextStart)
            return PitchPhraseScore(id: line.id, text: line.text, start: line.start,
                                    score: reason == nil ? statistics(from: line.start, to: finish).score : nil)
        }
        return PitchScoreReport(score: reason == nil ? stats.score : nil, matchedPercent: stats.matched,
                                voicedPercent: stats.voiced, referenceSeconds: stats.seconds,
                                recordedDuration: end, songDuration: songDuration, phrases: phrases,
                                unavailableReason: reason, version: 1)
    }
}
