import Foundation

/// Older manifests stored localized app messages rather than language-neutral keys.
/// Resolve only these known messages at display time; do not rewrite saved data.
enum SavedMessageLocalization {
    static func text(_ message: String) -> String {
        guard let key = legacyKeys[message] ?? (keys.contains(message) ? message : nil) else { return message }
        return Bundle.main.localizedString(forKey: key, value: message, table: "Localizable")
    }

    private static let legacyKeys: [String: String] = {
        guard let url = Bundle.main.url(forResource: "zh-Hans", withExtension: "lproj"),
              let chinese = Bundle(url: url) else { return [:] }
        return Dictionary(uniqueKeysWithValues: keys.map {
            (chinese.localizedString(forKey: $0, value: $0, table: "Localizable"), $0)
        })
    }()

    private static let keys = [
            "Embedded Lyrics",
            "The audio engine stopped. The recorded portion has been kept.",
            "This performance was not scored because audio played through the speaker. Sing again with headphones for pitch scoring.",
            "Recording could not keep up with the input. The recorded portion has been kept.",
            "Unable to read microphone timestamps. Recording stopped.",
            "Pitch analysis did not finish. Your recording has been kept.",
            "Pitch analysis did not finish. Your recording was saved.",
            "Less than one second of usable reference melody. Scoring is unavailable.",
            "Reference melody analysis failed. This performance will be recorded without a score.",
            "Recording is not ready. No score yet."
    ]
}
