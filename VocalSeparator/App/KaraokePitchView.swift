import SwiftUI

/// A song-clock piano roll: target bars ahead, the dry microphone trace behind the playhead.
struct KaraokePitchView: View {
    let reference: PitchReference?
    let trace: [PitchFrame]
    let currentTime: Double
    let isRecording: Bool
    let isPreparing: Bool
    let report: PitchScoreReport?
    let unavailableReason: String?
    var compact = false
    var mode: PitchScoringMode = .strict
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pitchRange: ClosedRange<Double> = 48...72

    private let violet = Color(red: 0.72, green: 0.57, blue: 1)
    private var time: Double { isRecording ? min(currentTime, trace.last?.time ?? currentTime) : currentTime }
    private var target: Double? {
        reference?.nearestFrame(at: time)
            .flatMap { abs($0.time - time) < 0.06 ? $0.reliableMidi : nil }
    }
    private var actual: Double? {
        guard isRecording, let last = trace.last, currentTime - last.time < 0.3 else { return nil }
        return last.reliableMidi
    }
    private var feedback: String {
        if isPreparing { return "正在生成参考旋律…" }
        if !isRecording { return "跟着音符，唱出你的旋律" }
        if unavailableReason != nil { return "本次暂不评分" }
        guard let target else { return "无参考音符 · 暂不评分" }
        guard let actual else { return "等待歌声" }
        if mode.isMatch(cents: (actual - target) * 100) { return "很准，保持住" }
        return actual > target ? "偏高 ↓" : "偏低 ↑"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path").foregroundStyle(violet)
                Text("音准").font(.caption.weight(.semibold))
                Spacer()
                Text("得分").font(.caption).foregroundStyle(.white.opacity(0.5))
                Text(report?.score.map(String.init) ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
            }.padding(.horizontal, 20).padding(.bottom, 8)
            Canvas { context, size in
                let playX = size.width * 0.26
                let pixelsPerSecond = size.width / 6
                let visible = reference?.frames(in: (time - 1.6)...(time + 4.5)) ?? []
                let lower = pitchRange.lowerBound, upper = pitchRange.upperBound
                func y(_ midi: Double) -> Double { max(9, min(size.height - 9, (upper - midi) / (upper - lower) * (size.height - 18) + 9)) }
                func x(_ t: Double) -> Double { playX + (t - time) * pixelsPerSecond }
                context.fill(Path(CGRect(x: 0, y: 0, width: playX, height: size.height)), with: .color(violet.opacity(0.09)))
                for index in 0...4 {
                    let line = Double(index) * size.height / 4
                    var path = Path(); path.move(to: CGPoint(x: 0, y: line)); path.addLine(to: CGPoint(x: size.width, y: line))
                    context.stroke(path, with: .color(.white.opacity(index == 0 || index == 4 ? 0.16 : 0.045)), lineWidth: 1)
                }
                // Merge consecutive detections at the same semitone into target capsules.
                var run: (start: Double, end: Double, note: Double)?
                func drawRun(_ run: (start: Double, end: Double, note: Double)) {
                    let rect = CGRect(x: x(run.start), y: y(run.note) - 3.5,
                                      width: max(3, (run.end - run.start) * pixelsPerSecond), height: 7)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3.5), with: .color(.white.opacity(0.20)))
                    context.stroke(Path(roundedRect: rect, cornerRadius: 3.5), with: .color(.white.opacity(0.10)), lineWidth: 1)
                }
                for frame in visible {
                    if let midi = frame.reliableMidi {
                        let note = midi.rounded()
                        if var old = run, old.note == note, frame.time - old.end <= PitchDetector.step * 1.5 {
                            old.end = frame.time + PitchDetector.step
                            run = old
                        } else {
                            if let old = run { drawRun(old) }
                            run = (frame.time, frame.time + PitchDetector.step, note)
                        }
                    } else if let old = run { drawRun(old); run = nil }
                }
                if let run { drawRun(run) }
                var previous: PitchFrame?
                for frame in trace where frame.time >= time - 1.6 && frame.time <= time {
                    guard let midi = frame.reliableMidi else { previous = nil; continue }
                    if let previous, let last = previous.reliableMidi, frame.time - previous.time < 0.05 {
                        var path = Path()
                        path.move(to: CGPoint(x: x(previous.time), y: y(last)))
                        path.addLine(to: CGPoint(x: x(frame.time), y: y(midi)))
                        context.stroke(path, with: .color(violet), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                    previous = frame
                }
                var playhead = Path()
                playhead.move(to: CGPoint(x: playX, y: 0)); playhead.addLine(to: CGPoint(x: playX, y: size.height))
                context.stroke(playhead, with: .color(violet.opacity(0.45)), lineWidth: 1)
                if let actual {
                    let centre = CGPoint(x: playX, y: y(actual))
                    context.fill(Path(ellipseIn: CGRect(x: centre.x - 12, y: centre.y - 12, width: 24, height: 24)),
                                 with: .color(violet.opacity(0.18)))
                    var diamond = Path()
                    diamond.move(to: CGPoint(x: centre.x, y: centre.y - 7))
                    diamond.addLine(to: CGPoint(x: centre.x + 7, y: centre.y))
                    diamond.addLine(to: CGPoint(x: centre.x, y: centre.y + 7))
                    diamond.addLine(to: CGPoint(x: centre.x - 7, y: centre.y)); diamond.closeSubpath()
                    context.fill(diamond, with: .color(.white))
                    if !reduceMotion, unavailableReason == nil, let target, mode.isMatch(cents: (actual - target) * 100) {
                        for index in 0..<6 {
                            let phase = (time * 1.5 + Double(index) / 6).truncatingRemainder(dividingBy: 1)
                            let point = CGPoint(x: centre.x - phase * 65, y: centre.y + sin(Double(index) * 2.4) * phase * 25)
                            let radius = 1.5 + (1 - phase) * 1.5
                            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                                         with: .color(.white.opacity(1 - phase)))
                        }
                    }
                }
                if reference == nil {
                    context.draw(Text(isPreparing ? "正在分析原唱音高" : "开始演唱后显示音符轨道")
                        .font(.caption).foregroundColor(.white.opacity(0.35)), at: CGPoint(x: size.width * 0.6, y: size.height / 2))
                }
            }
            .frame(height: compact ? 70 : 100).clipped().accessibilityHidden(true)
            HStack {
                Text(feedback).foregroundStyle(violet)
                Spacer()
                Text("\(mode.title) · 原调").foregroundStyle(.white.opacity(0.35))
            }.font(.system(size: 11)).padding(.horizontal, 20).padding(.top, 8)
        }
        .padding(.vertical, 10)
        .background(LinearGradient(colors: [violet.opacity(0.05), .clear], startPoint: .leading, endPoint: .trailing))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("音准轨道，\(mode.title)，\(feedback)")
        .accessibilityValue(report?.score.map { "当前得分 \($0) 分" } ?? "暂无分数")
        .accessibilityIdentifier("karaoke.pitch")
        .onChange(of: reference, initial: true) { _, reference in
            let pitches = (reference?.frames ?? []).compactMap(\.reliableMidi).sorted()
            let lower = pitches.isEmpty ? 48 : floor(pitches[pitches.count / 20]) - 3
            let upper = pitches.isEmpty ? 72 : max(lower + 12, ceil(pitches[pitches.count * 19 / 20]) + 3)
            pitchRange = lower...upper
        }
    }
}

struct PitchScoreCard: View {
    let report: PitchScoreReport
    var replayPhrase: ((Double) -> Void)? = nil
    private let violet = Color(red: 0.72, green: 0.57, blue: 1)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var summaryLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(spacing: 20))
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Label("音准成绩", systemImage: "waveform.path").font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(report.mode.title)
                    Text(report.recordedDuration + 0.5 < report.songDuration ? "已录片段" : "整首演唱")
                }.font(.caption).foregroundStyle(.secondary)
            }
            summaryLayout {
                ZStack {
                    Circle().stroke(violet.opacity(0.12), lineWidth: 6)
                    Circle().trim(from: 0, to: Double(report.score ?? 0) / 100)
                        .stroke(violet, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(report.score.map(String.init) ?? "—").font(.system(size: 38, weight: .semibold, design: .rounded))
                        Text("音准分").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 8) {
                    Text(report.assessment).font(.title3.bold()).foregroundStyle(violet)
                    if report.score != nil {
                        Text("音准命中 \(report.matchedPercent)%").font(.subheadline)
                        Text("演唱覆盖 \(report.voicedPercent)%").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text(report.unavailableReason ?? "暂无评分").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("以原唱参考旋律为准，仅评价本次录下部分的音高与演唱覆盖；不评价音色、歌词或情感。")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if report.score != nil, !report.phrases.isEmpty {
                DisclosureGroup("逐句成绩 · 点击回听") {
                    VStack(spacing: 12) {
                        ForEach(report.phrases) { phrase in
                            Button { replayPhrase?(phrase.start) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "play.circle").foregroundStyle(violet)
                                    Text(phrase.text).font(.subheadline).multilineTextAlignment(.leading).foregroundStyle(.primary)
                                    Spacer(minLength: 4)
                                    Text(phrase.score.map { "\($0)" } ?? "—").font(.headline.monospacedDigit()).foregroundStyle(violet)
                                }.padding(.vertical, 4)
                            }.buttonStyle(.plain).disabled(replayPhrase == nil)
                                .accessibilityLabel("\(phrase.text)，\(phrase.score.map { "\($0) 分，回听" } ?? "无可靠参考音符")")
                        }
                    }.padding(.top, 12)
                }.font(.subheadline).tint(violet)
            }
        }
        .padding(20)
        .background(violet.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(violet.opacity(0.16), lineWidth: 1))
        .accessibilityIdentifier("performance.pitchScore")
    }
}
