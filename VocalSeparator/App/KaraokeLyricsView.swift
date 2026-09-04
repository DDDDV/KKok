import SwiftUI

struct KaraokeLyricsView: View {
    let lyrics: TimedLyrics
    let currentTime: TimeInterval
    @ScaledMetric(relativeTo: .title3) private var fontSize: CGFloat = 20
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

    @ViewBuilder
    private func lyricText(_ line: LyricLine, active: Bool) -> some View {
        if !line.words.isEmpty, active {
            WordTimedLyricText(line: line, currentTime: currentTime, fontSize: fontSize)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.text)
        } else {
            Text(line.text.isEmpty ? "♪" : line.text)
                .foregroundColor(active ? .pink : .white.opacity(0.45))
        }
    }

}

/// TextKit keeps natural word wrapping, punctuation and composed Unicode intact on iOS 17.
/// Only drawing changes with the clock; text layout is reused throughout each lyric line.
private struct WordTimedLyricText: UIViewRepresentable {
    let line: LyricLine
    let currentTime: TimeInterval
    let fontSize: CGFloat

    func makeUIView(context: Context) -> KaraokeWordTextView { KaraokeWordTextView() }

    func updateUIView(_ view: KaraokeWordTextView, context: Context) {
        view.configure(line: line, time: currentTime, fontSize: fontSize)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: KaraokeWordTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

final class KaraokeWordTextView: UIView {
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private var line: LyricLine?
    private var fontSize: CGFloat = 0
    private var wordRanges: [NSRange] = []
    private var progress: [Double] = []

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.lineFragmentPadding = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(line: LyricLine, time: TimeInterval, fontSize: CGFloat) {
        if self.line != line || self.fontSize != fontSize {
            self.line = line
            self.fontSize = fontSize
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            storage.setAttributedString(NSAttributedString(string: line.text, attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .paragraphStyle: paragraph
            ]))
            var offset = 0
            wordRanges = line.words.map { word in
                let length = word.text.utf16.count
                defer { offset += length }
                return NSRange(location: offset, length: length)
            }
            invalidateIntrinsicContentSize()
        }
        progress = line.wordProgress(at: time)
        setNeedsDisplay()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        prepareLayout(width: size.width)
        return CGSize(width: size.width, height: ceil(layout.usedRect(for: container).maxY))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        prepareLayout(width: bounds.width)
        setNeedsDisplay()
    }

    private func prepareLayout(width: CGFloat) {
        let size = CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
        if container.size != size { container.size = size }
        layout.ensureLayout(for: container)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), storage.length > 0 else { return }
        prepareLayout(width: bounds.width)
        let allCharacters = NSRange(location: 0, length: storage.length)
        let allGlyphs = layout.glyphRange(for: container)
        storage.addAttribute(.foregroundColor, value: UIColor.white.withAlphaComponent(0.35),
                             range: allCharacters)
        layout.drawGlyphs(forGlyphRange: allGlyphs, at: .zero)
        storage.addAttribute(.foregroundColor, value: UIColor.systemPink, range: allCharacters)
        for (range, fill) in zip(wordRanges, progress) where fill > 0 {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var fragments: [CGRect] = []
            layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineRange, _ in
                fragments.append(self.layout.boundingRect(
                    forGlyphRange: NSIntersectionRange(glyphs, lineRange), in: self.container
                ))
            }
            // A timed word can wrap onto multiple visual lines. Sweep its actual
            // glyph fragments in order, never a rectangle spanning the whole lyric.
            var remaining = fragments.reduce(CGFloat(0)) { $0 + $1.width } * CGFloat(fill)
            context.saveGState()
            let clip = CGMutablePath()
            for fragment in fragments where remaining > 0 {
                clip.addRect(CGRect(x: fragment.minX, y: fragment.minY,
                                    width: min(fragment.width, remaining), height: fragment.height))
                remaining -= fragment.width
            }
            context.addPath(clip)
            context.clip()
            layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
            context.restoreGState()
        }
    }
}
