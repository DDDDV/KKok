import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    enum LibraryTab: Hashable { case songs, accompaniments, performances }
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: SeparationViewModel
    @State private var selectedTab: LibraryTab
    @State private var songSearch = ""
    @State private var accompanimentSearch = ""
    @State private var performanceSearch = ""
    @State private var onlyUnseparated = false
    @State private var sortByTitle = false
    @State private var isShowingLegal = false
    @State private var isShowingSong = false
    @State private var isShowingStage = false
    @State private var opensStageAfterDetail = false
    @State private var reviewingPerformance: SingingPerformance?
    @State private var deletingSong: LibrarySong?
    @State private var deletesSeparationOnly = false
    @State private var deletingPerformance: SingingPerformance?
    @State private var renamingSong: LibrarySong?
    @State private var editedTitle = ""
    @State private var isDiscardingRecording = false

    @MainActor
    init(viewModel: SeparationViewModel? = nil, initialTab: LibraryTab = .songs) {
        _viewModel = StateObject(wrappedValue: viewModel ?? SeparationViewModel())
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            libraryPage(.songs)
                .tabItem { Label("歌曲库", systemImage: "square.stack.fill") }.tag(LibraryTab.songs)
            libraryPage(.accompaniments)
                .tabItem { Label("伴奏库", systemImage: "waveform") }.tag(LibraryTab.accompaniments)
            libraryPage(.performances)
                .tabItem { Label("我的演唱", systemImage: "mic.fill") }.tag(LibraryTab.performances)
        }
        .tint(StudioTheme.accent)
        .preferredColorScheme(.light)
        .fileImporter(isPresented: $viewModel.isImporterPresented, allowedContentTypes: [.item],
                      allowsMultipleSelection: true, onCompletion: viewModel.handleFilesImport)
        .alert(item: Binding(get: { isShowingSong ? nil : viewModel.alert }, set: { viewModel.alert = $0 })) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
        }
        .sheet(isPresented: $isShowingLegal) { LegalView() }
        .sheet(isPresented: $isShowingSong, onDismiss: {
            if opensStageAfterDetail {
                opensStageAfterDetail = false
                isShowingStage = true
            } else if !viewModel.isProcessing { viewModel.playback.stop() }
        }) {
            SongDetailView(viewModel: viewModel) {
                opensStageAfterDetail = true
                isShowingSong = false
            }
        }
        .fullScreenCover(isPresented: $isShowingStage) {
            if let result = viewModel.result {
                KaraokeSessionView(result: result, lyrics: viewModel.importedLyrics?.lyrics,
                                   playback: viewModel.playback, recording: viewModel.recording,
                                   startSinging: viewModel.startSinging,
                                   togglePlayback: viewModel.toggleKaraokePlayback,
                                   artworkURL: viewModel.selectedSong.flatMap { viewModel.library.artworkURL(for: $0) })
            }
        }
        .sheet(item: $reviewingPerformance) { performance in
            PerformanceReviewView(performance: performance, store: viewModel.recording.store,
                                  playback: viewModel.playback, onSave: viewModel.recording.didSaveAdjustments)
        }
        .alert("重命名歌曲", isPresented: Binding(get: { renamingSong != nil }, set: { if !$0 { renamingSong = nil } })) {
            TextField("歌曲名称", text: $editedTitle)
            Button("保存") {
                if let song = renamingSong { viewModel.renameSong(song, title: editedTitle) }
                renamingSong = nil
            }
            Button("取消", role: .cancel) { renamingSong = nil }
        }
        .confirmationDialog(deletesSeparationOnly ? "删除分离结果？" : "删除这首歌曲？", isPresented: Binding(
            get: { deletingSong != nil }, set: { if !$0 { deletingSong = nil } }
        ), titleVisibility: .visible) {
            Button(deletesSeparationOnly ? "删除伴奏与人声" : "删除歌曲与分离结果", role: .destructive) {
                if let song = deletingSong { viewModel.deleteSong(song, separationOnly: deletesSeparationOnly) }
                deletingSong = nil
            }
        } message: {
            Text(deletesSeparationOnly ? "保留导入的原曲和已保存的演唱，可重新分离。" : "将删除本机原曲、对应歌词和分离结果。已保存的演唱不受影响。")
        }
        .confirmationDialog("删除这次演唱？", isPresented: Binding(
            get: { deletingPerformance != nil }, set: { if !$0 { deletingPerformance = nil } }
        ), titleVisibility: .visible) {
            Button("删除演唱", role: .destructive) {
                if let performance = deletingPerformance {
                    viewModel.recording.delete(performance, playback: viewModel.playback)
                }
                deletingPerformance = nil
            }
        } message: { Text("将删除这次演唱及其原始录音，歌曲和伴奏仍保留。") }
        .confirmationDialog("丢弃未保存的录音？", isPresented: $isDiscardingRecording, titleVisibility: .visible) {
            Button("丢弃录音", role: .destructive) { viewModel.recording.discardPending() }
        }
        .onChange(of: viewModel.recording.completedPerformance) { _, performance in
            if performance != nil { selectedTab = .performances }
        }
        .onChange(of: selectedTab) { _, _ in
            if !viewModel.isProcessing && !viewModel.recording.isBusy { viewModel.playback.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { viewModel.cancelForBackground() }
        }
    }

    private func libraryPage(_ tab: LibraryTab) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    pageHeader(tab)
                    if tab == .songs { songsContent }
                    if tab == .accompaniments { accompanimentsContent }
                    if tab == .performances { performancesContent }
                }
                .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 28)
            }
            .background(StudioTheme.paper)
            .toolbarBackground(StudioTheme.paper, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if viewModel.isProcessing || viewModel.isImporting { processingDock }
                if viewModel.recording.state == .needsRecovery && tab != .performances {
                    Button { selectedTab = .performances } label: {
                        Label("有一段演唱等待保存 · 前往处理", systemImage: "arrow.clockwise.circle")
                            .font(.subheadline).frame(maxWidth: .infinity).padding(16)
                            .background(.regularMaterial)
                    }
                }
            }
    }

    private func pageHeader(_ tab: LibraryTab) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("随 心 唱  /  YOUR MUSIC, YOUR VOICE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.2)
                    .foregroundStyle(StudioTheme.accent)
                Text(tab == .songs ? "歌曲库" : tab == .accompaniments ? "伴奏库" : "我的演唱")
                    .font(.system(size: 32, weight: .bold)).tracking(-1)
                    .foregroundStyle(StudioTheme.ink)
            }
            Spacer()
            Button { isShowingLegal = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 19))
                    .frame(width: 44, height: 44).background(.white.opacity(0.8), in: Circle())
            }
            .foregroundStyle(StudioTheme.ink).accessibilityLabel("关于与许可")
        }
    }

    private var songsContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            ZStack(alignment: .trailing) {
                RecordArtwork(title: "随心唱", size: 168).rotationEffect(.degrees(-18))
                    .offset(x: 38, y: -2).opacity(0.7).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 18) {
                    Text("把喜欢的歌\n唱成自己的。").font(.system(size: 27, weight: .semibold)).lineSpacing(4)
                    Text("从一首歌，开始你的音乐时刻")
                        .font(.caption).foregroundStyle(.white.opacity(0.65))
                    Button(action: importSongs) {
                        Label(viewModel.isImporting ? "正在导入…" : "导入歌曲", systemImage: "plus")
                            .font(.subheadline.bold()).padding(.horizontal, 18).padding(.vertical, 12)
                            .foregroundStyle(StudioTheme.ink).background(StudioTheme.mint, in: Capsule())
                    }
                    .disabled(!viewModel.canManageLibrary).accessibilityIdentifier("library.import")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            .foregroundStyle(.white).background(StudioTheme.ink)
            .clipShape(RoundedRectangle(cornerRadius: 26))

            StudioSearchField(text: $songSearch, placeholder: "搜索你的歌曲")
            HStack(spacing: 8) {
                filterPill("全部 \(viewModel.songs.count)", selected: !onlyUnseparated) { onlyUnseparated = false }
                filterPill("待分离", selected: onlyUnseparated) { onlyUnseparated = true }
                Spacer()
                Menu {
                    Button("最近导入", systemImage: sortByTitle ? "clock" : "checkmark") { sortByTitle = false }
                    Button("歌曲名称", systemImage: sortByTitle ? "checkmark" : "textformat") { sortByTitle = true }
                } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 40) }
                    .foregroundStyle(.secondary).accessibilityLabel("歌曲排序")
            }
            let songs = filteredSongs
            if !viewModel.isLibraryAvailable {
                StudioEmptyState(symbol: "externaldrive.badge.exclamationmark", title: "歌曲库暂时无法打开",
                                 message: "文件仍保存在本机，请重启应用后重试。")
            } else if viewModel.songs.isEmpty {
                StudioEmptyState(symbol: "music.note.list", title: "让第一首歌住进来",
                                 message: "从“文件”导入音频，支持一次选择多首。\n也可以为单首歌曲同时添加 LRC 歌词。")
            } else if songs.isEmpty {
                StudioEmptyState(symbol: "magnifyingglass", title: "没有找到歌曲", message: "试试其他关键词，或切换歌曲分类。")
            } else {
                LazyVStack(spacing: 0) { ForEach(songs) { song in songRow(song, separated: false) } }
            }
            Label("歌曲与作品保存在本机", systemImage: "internaldrive")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private var accompanimentsContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("舞台已备好。\n下一首，你来唱。")
                        .font(.system(size: 26, weight: .semibold)).lineSpacing(5)
                    Text("\(viewModel.separatedSongs.count) 首伴奏 · 随时开唱")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "waveform").font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(StudioTheme.accent).accessibilityHidden(true)
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.92, green: 0.91, blue: 0.86), in: RoundedRectangle(cornerRadius: 26))
            StudioSearchField(text: $accompanimentSearch, placeholder: "搜索已分离的歌曲")
            HStack {
                Text("准备开唱").font(.headline)
                Spacer()
                Text("伴奏 / 人声").font(.caption).foregroundStyle(.secondary)
            }
            let songs = viewModel.separatedSongs.filter { matches($0.title, query: accompanimentSearch) }
            if viewModel.separatedSongs.isEmpty {
                StudioEmptyState(symbol: "waveform.path", title: "你的专属伴奏，从这里开始",
                                 message: "在歌曲库选择歌曲，分离人声与伴奏。\n完成后，就能在这里进入演唱。",
                                 actionTitle: "去歌曲库", action: { selectedTab = .songs })
            } else if songs.isEmpty {
                StudioEmptyState(symbol: "magnifyingglass", title: "没有找到伴奏", message: "试试搜索其他歌曲名称。")
            } else {
                LazyVStack(spacing: 0) { ForEach(songs) { song in songRow(song, separated: true) } }
            }
        }
    }

    private var performancesContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 20) {
                Image(systemName: "mic.fill").font(.system(size: 30, weight: .light))
                    .foregroundStyle(StudioTheme.accent).frame(width: 68, height: 80)
                    .background(StudioTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))
                VStack(alignment: .leading, spacing: 7) {
                    Text("每一次开口，都值得留下。")
                        .font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text("\(viewModel.recording.performances.count) 个作品 · \(StudioTheme.duration(viewModel.recording.performances.reduce(0) { $0 + $1.duration }))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if viewModel.recording.state == .needsRecovery { recoveryCard }
            if viewModel.recording.state == .mixing {
                ProgressView("正在保存演唱…").frame(maxWidth: .infinity).padding(20).studioCard()
            }
            if let notice = viewModel.recording.notice {
                Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            if let error = viewModel.recording.errorText {
                Text(error).font(.caption).foregroundStyle(StudioTheme.accent)
            }
            StudioSearchField(text: $performanceSearch, placeholder: "搜索我的演唱")
            HStack {
                Text("我的作品").font(.headline)
                Spacer()
                Text("最近录制").font(.caption).foregroundStyle(.secondary)
            }
            let performances = viewModel.recording.performances.filter { matches($0.title, query: performanceSearch) }
            if viewModel.recording.performances.isEmpty {
                StudioEmptyState(symbol: "mic.badge.plus", title: "收藏你的第一段歌声",
                                 message: "选择一首伴奏，进入沉浸式演唱。\n录制完成后，作品会自动保存在这里。",
                                 actionTitle: "挑一首伴奏", action: { selectedTab = .accompaniments })
            } else if performances.isEmpty {
                StudioEmptyState(symbol: "magnifyingglass", title: "没有找到演唱", message: "试试搜索其他歌曲名称。")
            } else {
                LazyVStack(spacing: 0) { ForEach(performances) { performance in performanceRow(performance) } }
            }
        }
    }

    private func songRow(_ song: LibrarySong, separated: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                viewModel.selectSong(song)
                isShowingSong = true
            } label: {
                HStack(spacing: 14) {
                    RecordArtwork(title: song.title, artworkURL: viewModel.library.artworkURL(for: song))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(song.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(StudioTheme.ink)
                        if separated, let result = song.separation {
                            Text("\(StudioTheme.duration(result.duration)) · \(song.lyricsStatusText)")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("\(song.subtitle) · \(song.lyricsStatusText)").font(.caption).foregroundStyle(.secondary)
                            Text(song.separation == nil ? "待分离" : "伴奏已就绪")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(song.separation == nil ? .secondary : StudioTheme.accent)
                        }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if separated {
                Button {
                    viewModel.selectSong(song)
                    isShowingStage = true
                } label: {
                    Image(systemName: "mic.fill").frame(width: 42, height: 42)
                        .background(StudioTheme.accent.opacity(0.08), in: Circle())
                }.accessibilityLabel("演唱\(song.title)")
            }
            Menu {
                Button("查看歌曲", systemImage: "music.note") { viewModel.selectSong(song); isShowingSong = true }
                Button("重命名", systemImage: "pencil") { editedTitle = song.title; renamingSong = song }
                if let result = viewModel.library.result(for: song) {
                    ShareLink(item: result.accompanimentURL) { Label("导出伴奏", systemImage: "square.and.arrow.up") }
                    ShareLink(item: result.vocalsURL) { Label("导出人声", systemImage: "person.wave.2") }
                }
                Button(separated ? "删除分离结果" : "删除歌曲", systemImage: "trash", role: .destructive) {
                    deletesSeparationOnly = separated
                    deletingSong = song
                }
            } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44).foregroundStyle(.secondary) }
                .accessibilityLabel("\(song.title)的更多操作")
        }
        .disabled(!viewModel.canManageLibrary)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.06)).frame(height: 0.5).padding(.leading, 74) }
    }

    private func performanceRow(_ performance: SingingPerformance) -> some View {
        HStack(spacing: 14) {
            Button { reviewingPerformance = performance } label: {
                HStack(spacing: 14) {
                    RecordArtwork(title: performance.title, isPerformance: true)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(performance.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        Text(performance.createdAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(StudioTheme.duration(performance.duration)) · 回放与调整")
                            .font(.caption2).foregroundStyle(StudioTheme.accent)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.circle").font(.title2).foregroundStyle(StudioTheme.accent)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button("回放与调整", systemImage: "slider.horizontal.3") { reviewingPerformance = performance }
                ShareLink(item: viewModel.recording.store.mixURL(performance)) {
                    Label("导出演唱", systemImage: "square.and.arrow.up")
                }
                Button("删除演唱", systemImage: "trash", role: .destructive) { deletingPerformance = performance }
            } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44).foregroundStyle(.secondary) }
                .accessibilityLabel("\(performance.title)演唱的更多操作")
        }
        .disabled(viewModel.recording.isBusy || viewModel.isProcessing || viewModel.isImporting)
        .padding(.vertical, 13)
    }

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("有一段演唱等待保存", systemImage: "arrow.clockwise.circle").font(.headline)
            Text("录音已保留，可以继续保存为作品。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("重试保存", action: viewModel.recording.retrySaving).buttonStyle(PrimaryActionButtonStyle())
                Button("丢弃", role: .destructive) { isDiscardingRecording = true }.buttonStyle(SecondaryActionButtonStyle())
            }
        }.padding(18).studioCard()
    }

    private var processingDock: some View {
        HStack(spacing: 12) {
            ProgressView().tint(StudioTheme.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(viewModel.selectedSong?.title ?? "正在导入歌曲").font(.subheadline.bold()).lineLimit(1)
                Text(viewModel.statusText).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                if viewModel.isSeparating { ProgressView(value: viewModel.progress).tint(StudioTheme.accent) }
            }
            Spacer(minLength: 0)
            if viewModel.isProcessing { Button("取消", action: viewModel.cancel).font(.caption.bold()) }
        }
        .padding(16).background(.regularMaterial)
    }

    private var filteredSongs: [LibrarySong] {
        let songs = viewModel.songs.filter {
            matches($0.title, query: songSearch) && (!onlyUnseparated || $0.separation == nil)
        }
        return sortByTitle ? songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : songs
    }

    private func matches(_ title: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || title.localizedStandardContains(query)
    }

    private func filterPill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action).font(.caption.weight(.semibold))
            .padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundStyle(selected ? .white : StudioTheme.ink)
            .background(selected ? StudioTheme.ink : .clear, in: Capsule())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func importSongs() {
        viewModel.isSelectingLyrics = false
        viewModel.isImporterPresented = true
    }
}
