import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AudioExportFormat.preferenceKey) private var storedFormat = AudioExportFormat.wav.rawValue
    @AppStorage(PitchScoringSettings.enabledKey) private var scoringEnabled = true
    @AppStorage(PitchScoringSettings.modeKey) private var storedScoringMode = PitchScoringMode.strict.rawValue
    @State private var showingAbout = false
    @State private var showingPurchase = false
    @ObservedObject private var purchases = ExportPurchaseController.shared

    private var selectedFormat: AudioExportFormat { AudioExportFormat(rawValue: storedFormat) ?? .wav }
    private var scoringMode: PitchScoringMode { PitchScoringMode(rawValue: storedScoringMode) ?? .strict }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Lifetime Export")) {
                    Button { showingPurchase = true } label: {
                        Label(purchases.isUnlocked ? String(localized: "Lifetime Export Unlocked") : String(localized: "Unlock Lifetime Export"),
                              systemImage: purchases.isUnlocked ? "checkmark.seal.fill" : "lock.open")
                    }
                    .accessibilityIdentifier("settings.purchase")
                    Text(String(localized: "One purchase. Unlimited exports. No subscription or recurring fees."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    Toggle(String(localized: "Enable Pitch Scoring"), isOn: $scoringEnabled)
                        .accessibilityIdentifier("settings.pitchScoringEnabled")
                    Picker(String(localized: "Scoring Mode"), selection: Binding(
                        get: { scoringMode }, set: { storedScoringMode = $0.rawValue }
                    )) {
                        ForEach(PitchScoringMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .disabled(!scoringEnabled)
                    .accessibilityIdentifier("settings.pitchScoringMode")
                    if scoringEnabled {
                        Text(scoringMode.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                } header: { Text(String(localized: "Performance Scoring")) } footer: {
                    Text(String(localized: "Changes apply to your next performance. Turning scoring off hides the pitch track and stops new scores from being generated. Existing scores and scoring modes are kept."))
                }
                Section {
                    Picker(String(localized: "Export Format"), selection: Binding(
                        get: { selectedFormat }, set: { storedFormat = $0.rawValue }
                    )) {
                        ForEach(AudioExportFormat.allCases) { format in Text(format.title).tag(format) }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("settings.exportFormat")
                    Text(selectedFormat.detail).font(.subheadline).foregroundStyle(.secondary)
                } header: { Text(String(localized: "Audio Export")) } footer: {
                    Text(String(localized: "Applies to backing tracks, vocals, performances, and raw recordings. Audio is converted only when exported. Your local originals and saved adjustments stay the same."))
                }
                Section(String(localized: "Privacy and Terms")) {
                    Link(String(localized: "Privacy Policy"), destination: AppLegalLinks.privacy)
                        .accessibilityIdentifier("settings.privacyPolicy")
                    Link(String(localized: "Terms of Service"), destination: AppLegalLinks.terms)
                        .accessibilityIdentifier("settings.termsOfService")
                }
                Section(String(localized: "About")) {
                    Button(String(localized: "About and Licenses")) { showingAbout = true }
                    NavigationLink(String(localized: "MP3 Encoding and Open Source License")) { LAMELicenseView() }
                }
            }
            .navigationTitle(String(localized: "Settings"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } } }
            .sheet(isPresented: $showingAbout) { LegalView() }
            .sheet(isPresented: $showingPurchase) { ExportPurchaseView() }
        }
        .tint(StudioTheme.accent)
    }
}

struct LAMELicenseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("LAME 4.0").font(.title2.bold())
                Text(String(localized: "This app encodes MP3 using a separate LAME dynamic library distributed under GNU LGPL 2.1. Copyright belongs to the original LAME authors. Full notices are included in the source package below."))
                Link(String(localized: "LAME Website"), destination: URL(string: "https://lame.sourceforge.io/")!)
                if let source = Bundle.main.url(forResource: "LAME-4.0-source", withExtension: "zip") {
                    ShareLink(item: source) { Label(String(localized: "Export Full Source and Build Instructions"), systemImage: "square.and.arrow.up") }
                }
                Text(String(localized: "You may modify and replace LAME under its license and perform reverse engineering needed to debug those changes. The app's other terms do not restrict these rights. The source package includes instructions for rebuilding and replacing the dynamic library."))
                Text(licenseText).font(.caption.monospaced()).textSelection(.enabled)
            }.padding(20)
        }
        .navigationTitle(String(localized: "Open Source License")).navigationBarTitleDisplayMode(.inline)
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LAME-LGPL-2.1", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return String(localized: "The license could not be loaded. Please read the GNU LGPL on the LAME website.")
        }
        return text
    }
}
