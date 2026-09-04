import AVFoundation

struct PerformanceMixSettings: Codable, Equatable, Sendable {
    var vocalVolume: Double = 1
    var effect: VocalEffect = .natural

    func validate() throws {
        guard vocalVolume.isFinite, (0...2).contains(vocalVolume) else {
            throw SingingError.invalidSettings
        }
    }
}

enum VocalEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case natural, bathroom, hallway, concertHall

    var id: String { rawValue }
    var title: String {
        switch self {
        case .natural: return "原声"
        case .bathroom: return "浴室"
        case .hallway: return "楼道"
        case .concertHall: return "音乐厅"
        }
    }
    var symbol: String {
        switch self {
        case .natural: return "mic"
        case .bathroom: return "shower"
        case .hallway: return "door.left.hand.open"
        case .concertHall: return "music.note.house"
        }
    }
    var reverbPreset: AVAudioUnitReverbPreset {
        switch self {
        case .natural, .bathroom: return .smallRoom
        case .hallway: return .mediumHall
        case .concertHall: return .largeHall
        }
    }
    var wetDryMix: Float {
        switch self {
        case .natural: return 0
        case .bathroom: return 30
        case .hallway: return 40
        case .concertHall: return 35
        }
    }
}
