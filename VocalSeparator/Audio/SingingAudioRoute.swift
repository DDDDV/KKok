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

    var outputName: String { ListFormatter.localizedString(byJoining: outputs.map(\.name)) }
    var inputName: String {
        ListFormatter.localizedString(byJoining: inputs.map {
            $0.type == .builtInMic ? String(localized: "Phone microphone") : $0.name
        })
    }
    var symbol: String { usesHeadphones ? "headphones" : "speaker.wave.2" }

    func guidance(isRecording: Bool) -> String {
        if isWireless {
            if !isRecording { return String(localized: "Audio plays through wireless headphones while the phone or an external microphone records your voice. Keep the phone close to your mouth when using its microphone.") }
            let microphone = inputName.isEmpty ? String(localized: "Current microphone") : inputName
            let placement = inputs.contains { $0.type == .builtInMic } ? String(localized: "Keep the phone close to your mouth. ") : ""
            return String(localized: "Recording with \(microphone). \(placement)Wireless headphones may still have a timing offset.")
        }
        return usesHeadphones ? String(localized: "Headphones connected. You are ready to sing.") : String(localized: "Wear headphones to reduce backing track sound in your recording.")
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
