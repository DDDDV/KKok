import Foundation

enum AudioExportFormat: String, CaseIterable, Identifiable, Sendable {
    case wav, mp3, aac, alac

    static let preferenceKey = "audio.exportFormat"
    var id: String { rawValue }
    var fileExtension: String { self == .aac || self == .alac ? "m4a" : rawValue }
    var title: String {
        switch self {
        case .wav: return "WAV · 原始精度"
        case .mp3: return "MP3 · 通用分享"
        case .aac: return "AAC（M4A）· 小巧便携"
        case .alac: return "ALAC（M4A）· 无损压缩"
        }
    }
    var detail: String {
        switch self {
        case .wav: return "未压缩，保留内部 WAV 的采样率和精度，文件较大。"
        case .mp3: return "有损压缩，双声道 256 kbps、单声道 128 kbps，44.1 kHz。"
        case .aac: return "有损压缩，双声道 256 kbps、单声道 128 kbps，44.1 kHz。"
        case .alac: return "以 16／24 位整数无损压缩；浮点或更高精度音频会转换为 24 位整数。要保留完整浮点精度，请选择 WAV。"
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
