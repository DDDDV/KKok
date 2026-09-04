import SwiftUI

enum StudioTheme {
    static let accent = Color(red: 0.78, green: 0.23, blue: 0.19)
    static let paper = Color(red: 0.97, green: 0.96, blue: 0.94)
    static let ink = Color(red: 0.15, green: 0.18, blue: 0.19)
    static let stage = Color(red: 0.035, green: 0.065, blue: 0.075)
    static let mint = Color(red: 0.71, green: 0.90, blue: 0.78)

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
            [Color(red: 0.80, green: 0.42, blue: 0.30), Color(red: 0.39, green: 0.20, blue: 0.21)],
            [Color(red: 0.40, green: 0.59, blue: 0.51), Color(red: 0.13, green: 0.29, blue: 0.28)],
            [Color(red: 0.50, green: 0.51, blue: 0.68), Color(red: 0.23, green: 0.24, blue: 0.40)],
            [Color(red: 0.75, green: 0.60, blue: 0.37), Color(red: 0.37, green: 0.28, blue: 0.22)]
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
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary).accessibilityLabel("清除搜索")
            }
        }
        .padding(14)
        .background(.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
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
            .foregroundStyle(colorScheme == .dark ? .white : StudioTheme.ink)
            .background(colorScheme == .dark ? .white.opacity(0.09) : .black.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 16))
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.38)
    }
}

extension View {
    func studioCard() -> some View {
        background(.background, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).stroke(.primary.opacity(0.05), lineWidth: 1) }
    }
}
