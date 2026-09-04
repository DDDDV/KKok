import SwiftUI

struct KaraokeLyricsView: View {
    let lyrics: TimedLyrics
    let currentTime: TimeInterval
    private var activeIDs: [Int] { lyrics.activeLineIDs(at: currentTime) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 22) {
                    ForEach(lyrics.lines) { line in
                        lyricText(line, active: activeIDs.contains(line.id))
                            .font(.title3.weight(activeIDs.contains(line.id) ? .bold : .medium))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .id(line.id)
                            .accessibilityAddTraits(activeIDs.contains(line.id) ? .isSelected : [])
                    }
                }
                .padding(.vertical, 100)
                .padding(.horizontal, 8)
            }
            .frame(height: 300)
            .onChange(of: activeIDs, initial: true) { _, ids in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(ids.first ?? lyrics.scrollLineID(at: currentTime), anchor: .center)
                }
            }
            .onChange(of: lyrics) { _, _ in
                proxy.scrollTo(activeIDs.first ?? lyrics.scrollLineID(at: currentTime), anchor: .center)
            }
        }
    }

    private func lyricText(_ line: LyricLine, active: Bool) -> Text {
        guard !line.words.isEmpty, active else {
            return Text(line.text.isEmpty ? "♪" : line.text)
                .foregroundColor(active ? .pink : .white.opacity(0.45))
        }
        return line.words.reduce(Text("")) { text, word in
            text + Text(word.text).foregroundColor(word.start <= currentTime ? .pink : .white)
        }
    }

}
