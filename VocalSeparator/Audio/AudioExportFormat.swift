import Foundation

enum AudioExportFormat: String, CaseIterable, Identifiable, Sendable {
    case wav, mp3, aac, alac

    static let preferenceKey = "audio.exportFormat"
    var id: String { rawValue }
    var fileExtension: String { self == .aac || self == .alac ? "m4a" : rawValue }
    var title: String {
        switch self {
        case .wav: return String(localized: "WAV · Original Quality")
        case .mp3: return String(localized: "MP3 · Easy Sharing")
        case .aac: return String(localized: "AAC (M4A) · Compact")
        case .alac: return String(localized: "ALAC (M4A) · Lossless Compression")
        }
    }
    var detail: String {
        switch self {
        case .wav: return String(localized: "Uncompressed. Preserves the internal WAV sample rate and precision, with larger files.")
        case .mp3: return String(localized: "Lossy compression at 44.1 kHz: 256 kbps stereo or 128 kbps mono.")
        case .aac: return String(localized: "Lossy compression at 44.1 kHz: 256 kbps stereo or 128 kbps mono.")
        case .alac: return String(localized: "Lossless compression of 16- or 24-bit integer audio. Floating-point or higher-precision audio is converted to 24-bit integers. Choose WAV to preserve full floating-point precision.")
        }
    }

    static func selected(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .wav
    }
}

struct AudioExportRequest: Identifiable, Sendable {
    let id = UUID()
    let sourceURL: URL
    let title: String
    let format: AudioExportFormat

    init(sourceURL: URL, title: String, format: AudioExportFormat = .selected()) {
        self.sourceURL = sourceURL
        self.title = title
        self.format = format
    }
}
