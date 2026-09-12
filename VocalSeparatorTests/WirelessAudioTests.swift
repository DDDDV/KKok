import AVFoundation
import XCTest
import UIKit
@testable import VocalSeparator

final class WirelessAudioTests: XCTestCase {
    static let phone = SingingAudioRoute.Port(id: "phone", name: "iPhone Microphone", type: .builtInMic)
    static let wirelessRoute = SingingAudioRoute(
        inputs: [phone], outputs: [.init(id: "airpods", name: "AirPods Pro", type: .bluetoothA2DP)],
        sampleRate: 48_000, inputLatency: 0.02, outputLatency: 0.24, ioBufferDuration: 0.01)
    static let speakerRoute = SingingAudioRoute(
        inputs: [phone], outputs: [.init(id: "speaker", name: "iPhone 扬声器", type: .builtInSpeaker)],
        sampleRate: 48_000, inputLatency: 0.02, outputLatency: 0.01, ioBufferDuration: 0.01)

    func testRecordingAllowsMusicProfileWithoutEnablingCallProfile() {
        XCTAssertTrue(SingingAudioSessionPolicy.categoryOptions.contains(.allowBluetoothA2DP))
        XCTAssertFalse(SingingAudioSessionPolicy.categoryOptions.contains(.allowBluetoothHFP))
        let headset = SingingAudioRoute.Port(id: "hfp", name: "AirPods", type: .bluetoothHFP)
        XCTAssertEqual(SingingAudioSessionPolicy.preferredInput(in: [headset, Self.phone], wirelessOutput: true), Self.phone)
        XCTAssertNil(SingingAudioSessionPolicy.preferredInput(in: [headset], wirelessOutput: true))
    }

    func testWirelessPreferencePreservesExternalMicrophonesAndWiredRouting() {
        let usb = SingingAudioRoute.Port(id: "usb", name: "USB Microphone", type: .usbAudio)
        let wired = SingingAudioRoute.Port(id: "wired", name: "耳机麦克风", type: .headsetMic)
        XCTAssertEqual(SingingAudioSessionPolicy.preferredInput(in: [Self.phone, usb], wirelessOutput: true), usb)
        XCTAssertEqual(SingingAudioSessionPolicy.preferredInput(in: [Self.phone, wired], wirelessOutput: true), wired)
        XCTAssertNil(SingingAudioSessionPolicy.preferredInput(in: [Self.phone, wired], wirelessOutput: false))
    }

    func testWirelessStartupRejectsUnexpectedSpeakerFallback() {
        XCTAssertThrowsError(try SingingAudioSessionPolicy.validateOutput(wasWireless: true, route: Self.speakerRoute))
        XCTAssertThrowsError(try SingingAudioSessionPolicy.validateOutput(wasWireless: true,
                                                                          route: .init(inputs: [], outputs: [])))
        XCTAssertNoThrow(try SingingAudioSessionPolicy.validateOutput(wasWireless: true, route: Self.wirelessRoute))
        XCTAssertNoThrow(try SingingAudioSessionPolicy.validateOutput(wasWireless: false, route: Self.speakerRoute))
    }

    func testRouteMessagesDescribeActualInputAndDoNotClaimHeadphonesOnSpeaker() {
        XCTAssertEqual(Self.wirelessRoute.outputName, "AirPods Pro")
        XCTAssertTrue(Self.wirelessRoute.guidance(isRecording: true).contains("手机麦克风"))
        let external = SingingAudioRoute(inputs: [.init(id: "usb", name: "USB 话筒", type: .usbAudio)],
                                        outputs: Self.wirelessRoute.outputs)
        XCTAssertTrue(external.guidance(isRecording: true).contains("USB 话筒"))
        XCTAssertFalse(Self.speakerRoute.usesHeadphones)
        XCTAssertFalse(SingingAudioRoute(inputs: [], outputs: []).usesHeadphones)
        XCTAssertFalse(Self.speakerRoute.guidance(isRecording: false).contains("已连接"))
    }

    func testCaptureConfigurationTracksDeviceProfileClockAndLatencyNotNames() {
        let route = Self.wirelessRoute
        var changed = route
        changed.sampleRate = 16_000
        XCTAssertFalse(route.hasSameCaptureConfiguration(as: changed))
        changed = route
        changed.outputLatency += 0.1
        XCTAssertFalse(route.hasSameCaptureConfiguration(as: changed))
        changed = route
        changed.ioBufferDuration = 0.1
        XCTAssertFalse(route.hasSameCaptureConfiguration(as: changed))
        let call = SingingAudioRoute(inputs: route.inputs,
            outputs: [.init(id: "airpods", name: "AirPods Pro", type: .bluetoothHFP)],
            sampleRate: route.sampleRate, inputLatency: route.inputLatency,
            outputLatency: route.outputLatency, ioBufferDuration: route.ioBufferDuration)
        XCTAssertFalse(route.hasSameCaptureConfiguration(as: call))
        let renamed = SingingAudioRoute(inputs: route.inputs,
            outputs: [.init(id: "airpods", name: "我的耳机", type: .bluetoothA2DP)],
            sampleRate: route.sampleRate, inputLatency: route.inputLatency,
            outputLatency: route.outputLatency, ioBufferDuration: route.ioBufferDuration)
        XCTAssertTrue(route.hasSameCaptureConfiguration(as: renamed))
    }

    func testLatencyUsesOneEstimateAndFallsBackOnlyWhenNodeEstimateIsUnavailable() {
        XCTAssertEqual(SingingAudioSessionPolicy.latency(node: 0.24, session: 0.2), 0.24)
        for unknown in [0, -1, Double.nan, Double.infinity] {
            XCTAssertEqual(SingingAudioSessionPolicy.latency(node: unknown, session: 0.24), 0.24)
        }
        XCTAssertEqual(SingingAudioSessionPolicy.latency(node: 0, session: .nan), 0)
    }

    func testWirelessLatencyTrimmingPreservesVoiceAlignmentAndExportAtDifferentRates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for rate in [16_000.0, 44_100, 48_000] {
            let voice = root.appendingPathComponent("voice-\(rate).wav")
            let worker = try SingingCaptureWorker(url: voice, sampleRate: rate, duration: 0.5, analyzePitch: false)
            let origin = 10 + SingingAudioSessionPolicy.latency(node: 0, session: 0.24) + 0.02
            worker.begin(at: origin)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            // One input block spans preroll and the take. A pulse at heard music time 0.1 s
            // must still be at 0.1 s after trimming and the export resampler.
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rate * 0.8)))
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) {
                let time = Double(i) / rate - 0.1
                buffer.floatChannelData![0][i] = time >= 0.1 && time < 0.15 ? 0.3 : 0
            }
            worker.enqueue(buffer, hostTime: AVAudioTime.hostTime(forSeconds: origin - 0.1))
            worker.finish()
            XCTAssertNil(worker.failure)
            XCTAssertEqual(try AVAudioFile(forReading: voice).length, Int64(rate * 0.5))
            let backing = root.appendingPathComponent("backing-\(rate).wav")
            let output = root.appendingPathComponent("mix-\(rate).wav")
            try SingingFixtures.write(backing, seconds: 0.5, channels: 2) { _, _ in 0 }
            _ = try PerformanceMixer().mix(microphoneURL: voice, accompanimentURL: backing, outputURL: output)
            let samples = try SingingFixtures.read(output)[0]
            XCTAssertEqual(samples.count, 22_050)
            XCTAssertEqual(samples[2_205], 0, accuracy: 0.001)
            XCTAssertEqual(samples[5_292], 0.3, accuracy: 0.001)
            XCTAssertEqual(samples[8_820], 0, accuracy: 0.001)
        }
    }

    @MainActor
    func testIdlePlaybackCannotDeactivateRecordingSessionOrChangeIdleTimer() throws {
        var deactivations = 0
        let playback = AudioPlaybackController(deactivateSession: { deactivations += 1 })
        defer { playback.stop(); UIApplication.shared.isIdleTimerDisabled = false }
        UIApplication.shared.isIdleTimerDisabled = true
        playback.pause()
        playback.stop()
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        XCTAssertEqual(deactivations, 0)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        try playback.toggle(AudioTestFixtures.url())
        playback.pause()
        playback.stop()
        XCTAssertEqual(deactivations, 1)
        // The injected deactivation counts ownership without changing the real session.
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @MainActor
    func testStartupAndUnchangedRouteNotificationsDoNotEndTake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var route = Self.speakerRoute
        let capture = FixtureCapture()
        capture.didStart = {
            route = Self.wirelessRoute
            Self.postRouteChange(.newDeviceAvailable)
        }
        let controller = SingingRecordingController(store: PerformanceStore(root: root), capture: capture,
            requestPermission: { true }, readScoringSettings: { .init(isEnabled: false) }, readAudioRoute: { route })
        let url = try AudioTestFixtures.url()
        await controller.start(result: SeparationResult(sourceName: "无线耳机", vocalsURL: url, accompanimentURL: url, duration: 2),
                               lyrics: nil, playback: AudioPlaybackController())
        for reason: AVAudioSession.RouteChangeReason in [.newDeviceAvailable, .categoryChange, .routeConfigurationChange] {
            Self.postRouteChange(reason)
        }
        await Task.yield()
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(capture.stopCount, 0)
        XCTAssertEqual(controller.audioRoute, Self.wirelessRoute)
        controller.finish()
        try await waitForSave(controller)
        XCTAssertEqual(controller.performances.count, 1)
    }

    @MainActor
    func testActualWirelessRouteOrClockChangeSavesTakeOnce() async throws {
        for reason: AVAudioSession.RouteChangeReason in [.oldDeviceUnavailable, .override, .routeConfigurationChange] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var route = Self.wirelessRoute
            let capture = FixtureCapture()
            let controller = SingingRecordingController(store: PerformanceStore(root: root), capture: capture,
                requestPermission: { true }, readScoringSettings: { .init(isEnabled: false) }, readAudioRoute: { route })
            let url = try AudioTestFixtures.url()
            await controller.start(result: SeparationResult(sourceName: "无线耳机", vocalsURL: url, accompanimentURL: url, duration: 2),
                                   lyrics: nil, playback: AudioPlaybackController())
            if reason == .routeConfigurationChange { route.outputLatency += 0.1 }
            else { route = Self.speakerRoute }
            Self.postRouteChange(reason)
            Self.postRouteChange(reason)
            try await waitForSave(controller)
            XCTAssertEqual(capture.stopCount, 1)
            XCTAssertEqual(controller.performances.count, 1)
            XCTAssertNotNil(controller.notice)
            XCTAssertEqual(controller.audioRoute, route)
        }
    }

    @MainActor
    private static func postRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification,
                                       object: nil,
                                       userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }

    @MainActor
    private func waitForSave(_ controller: SingingRecordingController) async throws {
        for _ in 0..<200 {
            if controller.state == .idle { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected a saved take")
    }
}
