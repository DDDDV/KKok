import Foundation

enum PitchScoringMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case casual, strict

    var id: String { rawValue }
    var title: String { self == .casual ? String(localized: "Casual Mode") : String(localized: "Strict Mode") }
    var detail: String {
        self == .casual
            ? String(localized: "More forgiving of small pitch differences for relaxed singing. Missed notes still reduce your score.")
            : String(localized: "Uses smaller pitch tolerances for focused practice.")
    }
    var fullCreditCents: Double { self == .casual ? 50 : 25 }
    var zeroCreditCents: Double { self == .casual ? 200 : 100 }
    var matchedCents: Double { self == .casual ? 100 : 50 }

    func points(forCents cents: Double) -> Double {
        guard cents.isFinite else { return 0 }
        return max(0, min(1, (zeroCreditCents - abs(cents)) / (zeroCreditCents - fullCreditCents)))
    }
    func isMatch(cents: Double) -> Bool { cents.isFinite && abs(cents) <= matchedCents }
}

struct PitchScoringSettings: Equatable, Sendable {
    static let enabledKey = "singing.pitchScoringEnabled"
    static let modeKey = "singing.pitchScoringMode"

    var isEnabled = true
    var mode: PitchScoringMode = .strict

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(isEnabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
             mode: PitchScoringMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .strict)
    }
}
