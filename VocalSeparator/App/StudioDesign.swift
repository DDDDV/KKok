import SwiftUI

private struct StudioCompactLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var studioCompactLayout: Bool {
        get { self[StudioCompactLayoutKey.self] }
        set { self[StudioCompactLayoutKey.self] = newValue }
    }
}

enum StudioTheme {
    static let accent = Color(red: 0.73, green: 0.19, blue: 0.14)
    static let paper = Color(red: 0.985, green: 0.966, blue: 0.939)
    static let ink = Color(red: 0.23, green: 0.15, blue: 0.13)
    static let stage = Color(red: 0.09, green: 0.045, blue: 0.04)
    static let cream = Color(red: 1, green: 0.96, blue: 0.88)
    static let blush = Color(red: 0.975, green: 0.90, blue: 0.86)
    static let border = Color(red: 0.89, green: 0.80, blue: 0.75)
    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.82, green: 0.22, blue: 0.16), Color(red: 0.65, green: 0.14, blue: 0.10)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static func duration(_ time: TimeInterval) -> String {
        let seconds = Int(max(0, time.isFinite ? time : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct RecordArtwork: View {
    var title: String
    var size: CGFloat = 60
    var isPerformance = false
    var artworkURL: URL? = nil
    @State private var artwork: UIImage?

    private var palette: [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.86, green: 0.35, blue: 0.25), Color(red: 0.59, green: 0.17, blue: 0.13)],
            [Color(red: 0.82, green: 0.51, blue: 0.38), Color(red: 0.51, green: 0.27, blue: 0.20)],
            [Color(red: 0.75, green: 0.36, blue: 0.31), Color(red: 0.46, green: 0.20, blue: 0.19)],
            [Color(red: 0.84, green: 0.61, blue: 0.42), Color(red: 0.56, green: 0.32, blue: 0.22)]
        ]
        let index = title.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % palettes.count }
        return palettes[index]
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.black.opacity(0.23)).padding(size * 0.12)
            ForEach(0..<5) { index in
                Circle().stroke(.white.opacity(0.10), lineWidth: 1)
                    .padding(size * (0.15 + CGFloat(index) * 0.045))
            }
            Circle().fill(palette[0]).frame(width: size * 0.23, height: size * 0.23)
            Image(systemName: isPerformance ? "mic.fill" : "music.note")
                .font(.system(size: size * 0.12, weight: .bold)).foregroundStyle(.white.opacity(0.9))
            if let artwork {
                Image(uiImage: artwork).resizable().scaledToFill().frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.19))
        .accessibilityHidden(true)
        .task(id: artworkURL) {
            artwork = nil
            guard let artworkURL else { return }
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: artworkURL) }.value
            guard !Task.isCancelled else { return }
            artwork = data.flatMap { UIImage(data: $0) }
        }
    }
}

struct StudioSearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).font(.subheadline)
                .autocorrectionDisabled()
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 32, height: 32) }
                    .foregroundStyle(.secondary).accessibilityLabel(String(localized: "Clear Search"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 50)
        .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(StudioTheme.border.opacity(0.5), lineWidth: 1) }
    }
}

struct StudioEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light))
                .foregroundStyle(StudioTheme.accent)
                .frame(width: 76, height: 76)
                .background(StudioTheme.accent.opacity(0.07), in: Circle())
            Text(title).font(.title3.bold())
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(.subheadline.bold())
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(StudioTheme.accent.opacity(0.08), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 28)
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.bold()).padding(.horizontal, 18).padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 16))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 14)
            .foregroundStyle(colorScheme == .dark ? .white : StudioTheme.accent)
            .background(colorScheme == .dark ? .white.opacity(0.09) : StudioTheme.blush,
                        in: RoundedRectangle(cornerRadius: 16))
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.38)
    }
}

extension View {
    func studioCard() -> some View {
        background(.background, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).stroke(StudioTheme.border.opacity(0.35), lineWidth: 1) }
    }
}

/// A shared hierarchy across all three libraries, echoing the app icon.
struct StudioHeroCard<Action: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.studioCompactLayout) private var compactLayout
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) {
                    Text(subtitle).font(.caption).foregroundStyle(StudioTheme.cream)
                        .fixedSize(horizontal: false, vertical: true)
                    action()
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            } else if compactLayout {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title.replacingOccurrences(of: "\n", with: " ")).font(.headline)
                        Text(subtitle).font(.caption).foregroundStyle(StudioTheme.cream)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    action().fixedSize(horizontal: true, vertical: false)
                }.padding(18)
            } else {
                expandedContent
            }
        }
        .foregroundStyle(.white)
        .background(StudioTheme.heroGradient, in: RoundedRectangle(cornerRadius: 28))
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(eyebrow).font(.caption.weight(.semibold)).foregroundStyle(StudioTheme.cream)
                    Text(title).font(.title2.bold()).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize {
                    Image("BrandArtwork").resizable().scaledToFit()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 25))
                        .rotationEffect(.degrees(8))
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                        .accessibilityHidden(true)
                }
            }
            Text(subtitle).font(.caption).foregroundStyle(StudioTheme.cream)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .foregroundStyle(.white).padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StudioHeroButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.bold())
            .padding(.horizontal, 18).padding(.vertical, 13).frame(minHeight: 44)
            .foregroundStyle(StudioTheme.accent)
            .background(StudioTheme.cream, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}
