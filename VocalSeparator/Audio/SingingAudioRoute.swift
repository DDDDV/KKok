import AVFoundation

/// A value snapshot lets route changes be compared with the route used to start a take.
struct SingingAudioRoute: Equatable {
    struct Port: Equatable {
        let id: String
        let name: String
        let type: AVAudioSession.Port

        init(id: String, name: String, type: AVAudioSession.Port) {
            self.id = id
            self.name = name
            self.type = type
        }

        init(_ port: AVAudioSessionPortDescription) {
            self.init(id: port.uid, name: port.portName, type: port.portType)
        }
    }

    let inputs: [Port]
    let outputs: [Port]
    var sampleRate: Double = 0
    var inputLatency: Double = 0
    var outputLatency: Double = 0
    var ioBufferDuration: Double = 0

    static func current() -> Self {
        let session = AVAudioSession.sharedInstance()
        return Self(inputs: session.currentRoute.inputs.map(Port.init),
                    outputs: session.currentRoute.outputs.map(Port.init),
                    sampleRate: session.sampleRate, inputLatency: session.inputLatency,
                    outputLatency: session.outputLatency, ioBufferDuration: session.ioBufferDuration)
    }

    var isWireless: Bool {
        outputs.contains { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.type) }
    }

    var usesHeadphones: Bool {
        !outputs.isEmpty && outputs.allSatisfy {
            [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.type)
        }
    }

    var outputName: String { outputs.map(\.name).joined(separator: "、") }
    var inputName: String { inputs.map { $0.type == .builtInMic ? "手机麦克风" : $0.name }.joined(separator: "、") }
    var symbol: String { usesHeadphones ? "headphones" : "speaker.wave.2" }

    func guidance(isRecording: Bool) -> String {
        if isWireless {
            if !isRecording { return "无线耳机播放，使用手机或外接麦克风收音；使用手机时请靠近嘴边。" }
            let microphone = inputName.isEmpty ? "当前麦克风" : inputName
            let placement = inputs.contains { $0.type == .builtInMic } ? "请将手机靠近嘴边。" : ""
            return "正在用\(microphone)收音；\(placement)无线耳机仍可能有同步偏差。"
        }
        return usesHeadphones ? "耳机已连接，可以开始演唱。" : "佩戴耳机可减少伴奏串入录音。"
    }

    func hasSameCaptureConfiguration(as other: Self) -> Bool {
        func samePorts(_ lhs: [Port], _ rhs: [Port]) -> Bool {
            let lhs = lhs.sorted { $0.id < $1.id }
            let rhs = rhs.sorted { $0.id < $1.id }
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.id == $1.id && $0.type == $1.type }
        }
        // Port names can change without changing the audio path. A changed clock or latency cannot.
        return samePorts(inputs, other.inputs) && samePorts(outputs, other.outputs)
            && abs(sampleRate - other.sampleRate) < 1
            && abs(inputLatency - other.inputLatency) < 0.005
            && abs(outputLatency - other.outputLatency) < 0.005
            && abs(ioBufferDuration - other.ioBufferDuration) < 0.005
    }
}

enum SingingAudioSessionPolicy {
    // Enabling HFP alongside A2DP gives the headset's call profile priority on dual-profile devices.
    // Keep music playback on A2DP and capture locally, without routing dry mic audio to the output.
    static let categoryOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]

    static func validateOutput(wasWireless: Bool, route: SingingAudioRoute) throws {
        // A headset may disconnect or only support HFP. Do not start the backing track aloud.
        if wasWireless, route.outputs.isEmpty || route.outputs.contains(where: {
            [.builtInSpeaker, .builtInReceiver].contains($0.type)
        }) {
            throw SingingError.wirelessOutputUnavailable
        }
    }

    static func preferredInput(in inputs: [SingingAudioRoute.Port], wirelessOutput: Bool) -> SingingAudioRoute.Port? {
        guard wirelessOutput else { return nil }
        // Respect a connected recording microphone before falling back to the phone microphone.
        return inputs.first { [.headsetMic, .usbAudio].contains($0.type) }
            ?? inputs.first { $0.type == .builtInMic }
    }

    static func latency(node: Double, session: Double) -> Double {
        // Node latency already includes the downstream path; never add session latency again.
        if node.isFinite, node > 0 { return node }
        return session.isFinite && session > 0 ? session : 0
    }
}
