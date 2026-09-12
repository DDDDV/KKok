import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AudioExportFormat.preferenceKey) private var storedFormat = AudioExportFormat.wav.rawValue
    @AppStorage(PitchScoringSettings.enabledKey) private var scoringEnabled = true
    @AppStorage(PitchScoringSettings.modeKey) private var storedScoringMode = PitchScoringMode.strict.rawValue
    @State private var showingAbout = false

    private var selectedFormat: AudioExportFormat { AudioExportFormat(rawValue: storedFormat) ?? .wav }
    private var scoringMode: PitchScoringMode { PitchScoringMode(rawValue: storedScoringMode) ?? .strict }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("启用音准评分", isOn: $scoringEnabled)
                        .accessibilityIdentifier("settings.pitchScoringEnabled")
                    Picker("评分模式", selection: Binding(
                        get: { scoringMode }, set: { storedScoringMode = $0.rawValue }
                    )) {
                        ForEach(PitchScoringMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .disabled(!scoringEnabled)
                    .accessibilityIdentifier("settings.pitchScoringMode")
                    if scoringEnabled {
                        Text(scoringMode.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                } header: { Text("演唱评分") } footer: {
                    Text("设置从下一次演唱生效。关闭后隐藏音准轨道，演唱不再生成分数。已有作品的分数和评分模式会保留。")
                }
                Section {
                    Picker("导出格式", selection: Binding(
                        get: { selectedFormat }, set: { storedFormat = $0.rawValue }
                    )) {
                        ForEach(AudioExportFormat.allCases) { format in Text(format.title).tag(format) }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("settings.exportFormat")
                    Text(selectedFormat.detail).font(.subheadline).foregroundStyle(.secondary)
                } header: { Text("音频导出") } footer: {
                    Text("应用于伴奏、人声、演唱和原始录音。导出时才转换格式，本机保存的原始音频和演唱调整不受影响。")
                }
                Section("关于") {
                    Button("关于与许可") { showingAbout = true }
                    NavigationLink("MP3 编码与开源许可") { LAMELicenseView() }
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showingAbout) { LegalView() }
        }
        .tint(StudioTheme.accent)
    }
}

struct LAMELicenseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("LAME 4.0").font(.title2.bold())
                Text("本应用使用独立的 LAME 动态库编码 MP3，并按 GNU LGPL 2.1 分发该库。版权属于 LAME 原作者，完整声明见下方源码包。")
                Link("LAME 项目网站", destination: URL(string: "https://lame.sourceforge.io/")!)
                if let source = Bundle.main.url(forResource: "LAME-4.0-source", withExtension: "zip") {
                    ShareLink(item: source) { Label("导出完整源码与构建说明", systemImage: "square.and.arrow.up") }
                }
                Text("你可以依许可修改、替换 LAME，并为调试这些修改进行必要的逆向工程。本应用的其他使用条款不限制这些权利。源码包包含重建动态库和替换方法。")
                Text(licenseText).font(.caption.monospaced()).textSelection(.enabled)
            }.padding(20)
        }
        .navigationTitle("开源许可").navigationBarTitleDisplayMode(.inline)
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LAME-LGPL-2.1", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "许可证暂时无法读取，请在 LAME 项目网站查看 GNU LGPL。"
        }
        return text
    }
}
