import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    enum LibraryTab: Hashable { case songs, accompaniments, performances }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var viewModel: SeparationViewModel
    @State private var selectedTab: LibraryTab
    @State private var songSearch = ""
    @State private var accompanimentSearch = ""
    @State private var performanceSearch = ""
    @State private var onlyUnseparated = false
    @AppStorage("library.songSort") private var songSort: LibrarySortOrder = .recent
    @AppStorage("library.accompanimentSort") private var accompanimentSort: LibrarySortOrder = .recent
    @AppStorage("library.performanceSort") private var performanceSort: LibrarySortOrder = .recent
    @State private var favoriteSongsOnly = false
    @State private var favoriteAccompanimentsOnly = false
    @State private var lyricsReadyOnly = false
    @State private var isShowingLegal = false
    @State private var isShowingSong = false
    @State private var isShowingStage = false
    @State private var opensStageAfterDetail = false
    @State private var reviewingPerformance: SingingPerformance?
    @State private var deletingSong: LibrarySong?
    @State private var deletesSeparationOnly = false
    @State private var deletingPerformance: SingingPerformance?
    @State private var renamingSong: LibrarySong?
    @State private var renamingPerformance: SingingPerformance?
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
        .alert(renamingPerformance == nil ? "重命名歌曲" : "重命名演唱", isPresented: Binding(
            get: { renamingSong != nil || renamingPerformance != nil },
            set: { if !$0 { renamingSong = nil; renamingPerformance = nil } }
        )) {
            TextField("名称", text: $editedTitle)
            Button("保存") {
                if let song = renamingSong { viewModel.renameSong(song, title: editedTitle) }
                if let performance = renamingPerformance { viewModel.recording.rename(performance, title: editedTitle) }
                renamingSong = nil
                renamingPerformance = nil
            }
            .disabled(editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) { renamingSong = nil; renamingPerformance = nil }
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
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    pageHeader(tab)
                    if tab == .songs { songsContent }
                    if tab == .accompaniments { accompanimentsContent }
                    if tab == .performances { performancesContent }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 28)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .foregroundStyle(StudioTheme.ink)
            .environment(\.studioCompactLayout, geometry.size.height < 620)
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
    }

    private func pageHeader(_ tab: LibraryTab) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Label("随心唱 · 从心开唱", systemImage: "heart.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(StudioTheme.accent)
                Text(tab == .songs ? "歌曲库" : tab == .accompaniments ? "伴奏库" : "我的演唱")
                    .font(.largeTitle.bold()).tracking(-1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 12)
            Button { isShowingLegal = true } label: {
                Image(systemName: "info").font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44).background(.white.opacity(0.9), in: Circle())
                    .overlay { Circle().stroke(StudioTheme.border.opacity(0.5), lineWidth: 1) }
            }
            .accessibilityLabel("关于与许可")
        }
    }

    private var songsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioHeroCard(eyebrow: "你的私人歌单", title: "喜欢的歌，\n随心唱。",
                           subtitle: "\(viewModel.songs.count) 首歌曲 · \(viewModel.separatedSongs.count) 首伴奏已就绪") {
                Button(action: importSongs) {
                    Label(viewModel.isImporting ? "正在导入…" : "导入歌曲", systemImage: "plus")
                }
                .buttonStyle(StudioHeroButtonStyle())
                .disabled(!viewModel.canManageLibrary).accessibilityIdentifier("library.import")
            }
            StudioSearchField(text: $songSearch, placeholder: "搜索你的歌曲")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterPill("全部", symbol: "music.note.list", selected: !onlyUnseparated && !favoriteSongsOnly) {
                        onlyUnseparated = false; favoriteSongsOnly = false
                    }
                    filterPill("收藏", symbol: "heart", selected: favoriteSongsOnly) { favoriteSongsOnly.toggle() }
                        .accessibilityIdentifier("library.songs.favorites")
                    filterPill("待分离", symbol: "waveform.path", selected: onlyUnseparated) { onlyUnseparated.toggle() }
                }
            }
            browserToolbar("我的歌曲", count: filteredSongs.count, sort: $songSort, identifier: "songs")
            if !viewModel.isLibraryAvailable {
                StudioEmptyState(symbol: "externaldrive.badge.exclamationmark", title: "歌曲库暂时无法打开",
                                 message: "文件仍保存在本机，请重启应用后重试。")
            } else if viewModel.songs.isEmpty {
                StudioEmptyState(symbol: "music.note.list", title: "让第一首歌住进来",
                                 message: "从“文件”一次导入多首音频，\n也可以为单首歌曲同时添加 LRC 歌词。")
            } else if filteredSongs.isEmpty {
                StudioEmptyState(symbol: favoriteSongsOnly ? "heart" : "magnifyingglass", title: "这里还没有歌曲",
                                 message: "点歌曲旁的爱心即可收藏，或试试其他筛选条件。",
                                 actionTitle: "显示全部歌曲", action: {
                    songSearch = ""; favoriteSongsOnly = false; onlyUnseparated = false
                })
            } else {
                LazyVStack(spacing: 10) { ForEach(filteredSongs) { song in songRow(song, separated: false) } }
            }
            Label("歌曲与作品保存在本机", systemImage: "internaldrive")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 4)
        }
    }

    private var accompanimentsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioHeroCard(eyebrow: "把舞台留给你", title: "下一首，\n你来唱。",
                           subtitle: "\(viewModel.separatedSongs.count) 首伴奏 · \(viewModel.separatedSongs.filter { $0.lyrics != nil }.count) 首同步歌词就绪") {
                Button {
                    if viewModel.selectRandomAccompaniment(from: filteredAccompaniments) { isShowingStage = true }
                } label: { Label("随机开唱", systemImage: "shuffle") }
                    .buttonStyle(StudioHeroButtonStyle())
                    .disabled(!viewModel.canManageLibrary || filteredAccompaniments.isEmpty)
                    .accessibilityHint("从当前筛选的伴奏中选择一首，进入演唱页面")
                    .accessibilityIdentifier("library.randomSing")
            }
            StudioSearchField(text: $accompanimentSearch, placeholder: "搜索已分离的歌曲")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterPill("全部", symbol: "waveform", selected: !favoriteAccompanimentsOnly && !lyricsReadyOnly) {
                        favoriteAccompanimentsOnly = false; lyricsReadyOnly = false
                    }
                    filterPill("收藏", symbol: "heart", selected: favoriteAccompanimentsOnly) { favoriteAccompanimentsOnly.toggle() }
                    filterPill("歌词就绪", symbol: "text.quote", selected: lyricsReadyOnly) { lyricsReadyOnly.toggle() }
                        .accessibilityIdentifier("library.lyricsReady")
                }
            }
            browserToolbar("准备开唱", count: filteredAccompaniments.count, sort: $accompanimentSort, identifier: "accompaniments")
            if viewModel.separatedSongs.isEmpty {
                StudioEmptyState(symbol: "waveform.path", title: "你的专属伴奏，从这里开始",
                                 message: "在歌曲库分离人声与伴奏，\n完成后就能在这里进入演唱。",
                                 actionTitle: "去歌曲库", action: { selectedTab = .songs })
            } else if filteredAccompaniments.isEmpty {
                StudioEmptyState(symbol: "magnifyingglass", title: "没有符合条件的伴奏",
                                 message: "试试其他关键词，或清除收藏与歌词筛选。",
                                 actionTitle: "显示全部伴奏", action: {
                    accompanimentSearch = ""; favoriteAccompanimentsOnly = false; lyricsReadyOnly = false
                })
            } else {
                LazyVStack(spacing: 10) { ForEach(filteredAccompaniments) { song in songRow(song, separated: true) } }
            }
        }
    }

    private var performancesContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioHeroCard(eyebrow: "每一次开口，都值得留下", title: "让歌声，\n成为作品。",
                           subtitle: "\(viewModel.recording.performances.count) 个作品 · 累计 \(StudioTheme.duration(viewModel.recording.performances.reduce(0) { $0 + $1.duration }))") {
                Button { selectedTab = .accompaniments } label: { Label("录一首新歌", systemImage: "mic.badge.plus") }
                    .buttonStyle(StudioHeroButtonStyle())
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
            browserToolbar("我的作品", count: filteredPerformances.count, sort: $performanceSort, identifier: "performances")
            if viewModel.recording.performances.isEmpty {
                StudioEmptyState(symbol: "mic.badge.plus", title: "留下你的第一段歌声",
                                 message: "选一首伴奏，进入沉浸式演唱。\n录制完成后，作品会自动保存在这里。")
            } else if filteredPerformances.isEmpty {
                StudioEmptyState(symbol: "magnifyingglass", title: "没有找到演唱", message: "试试搜索其他作品名称。",
                                 actionTitle: "显示全部作品", action: { performanceSearch = "" })
            } else {
                LazyVStack(spacing: 10) { ForEach(filteredPerformances) { performance in performanceRow(performance) } }
            }
        }
    }

    private func songRow(_ song: LibrarySong, separated: Bool) -> some View {
        HStack(spacing: 4) {
            Button {
                viewModel.selectSong(song)
                isShowingSong = true
            } label: {
                HStack(spacing: 12) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        RecordArtwork(title: song.title, size: 52, artworkURL: viewModel.library.artworkURL(for: song))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(song.title).font(.headline).lineLimit(2).foregroundStyle(StudioTheme.ink)
                        if separated, let result = song.separation {
                            Text("\(StudioTheme.duration(result.duration)) · \(song.lyrics == nil ? "可添加歌词" : "歌词就绪")")
                                .font(.caption).foregroundStyle(.secondary)
                            if song.isFavorite == true {
                                Label("已收藏", systemImage: "heart.fill").font(.caption2).foregroundStyle(StudioTheme.accent)
                            }
                        } else {
                            Text(song.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(song.separation == nil ? "待分离" : "伴奏已就绪")
                                .font(.caption2.weight(.medium)).foregroundStyle(StudioTheme.accent)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if separated {
                Button {
                    viewModel.selectSong(song)
                    isShowingStage = true
                } label: {
                    Image(systemName: "mic.fill").frame(width: 44, height: 44)
                        .background(StudioTheme.blush, in: Circle())
                }.accessibilityLabel("演唱\(song.title)")
                    .foregroundStyle(StudioTheme.accent)
            } else {
                Button { viewModel.toggleFavorite(song) } label: {
                    Image(systemName: song.isFavorite == true ? "heart.fill" : "heart")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("\(song.isFavorite == true ? "取消收藏" : "收藏")\(song.title)")
                .accessibilityIdentifier("library.favorite.\(song.id)")
                .foregroundStyle(StudioTheme.accent)
            }
            Menu {
                Button("查看歌曲", systemImage: "music.note") { viewModel.selectSong(song); isShowingSong = true }
                Button(song.isFavorite == true ? "取消收藏" : "收藏歌曲", systemImage: song.isFavorite == true ? "heart.slash" : "heart") {
                    viewModel.toggleFavorite(song)
                }
                Button("重命名", systemImage: "pencil") { editedTitle = song.title; renamingSong = song }
                if let result = viewModel.library.result(for: song) {
                    ShareLink(item: result.accompanimentURL) { Label("导出伴奏", systemImage: "square.and.arrow.up") }
                    ShareLink(item: result.vocalsURL) { Label("导出人声", systemImage: "person.wave.2") }
                }
                Button(separated ? "删除分离结果" : "删除歌曲", systemImage: "trash", role: .destructive) {
                    deletesSeparationOnly = separated
                    deletingSong = song
                }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(.secondary) }
                .accessibilityLabel("\(song.title)的更多操作")
        }
        .disabled(!viewModel.canManageLibrary)
        .padding(12).studioCard()
    }

    private func performanceRow(_ performance: SingingPerformance) -> some View {
        HStack(spacing: 4) {
            Button { reviewingPerformance = performance } label: {
                HStack(spacing: 12) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        RecordArtwork(title: performance.title, size: 52, isPerformance: true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(performance.title).font(.headline).lineLimit(2)
                        Text(performance.createdAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(StudioTheme.duration(performance.duration)) · 回放与调整")
                            .font(.caption2).foregroundStyle(StudioTheme.accent)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(StudioTheme.accent)
                        .frame(width: 44, height: 44)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button("回放与调整", systemImage: "slider.horizontal.3") { reviewingPerformance = performance }
                Button("重命名作品", systemImage: "pencil") { editedTitle = performance.title; renamingPerformance = performance }
                ShareLink(item: viewModel.recording.store.mixURL(performance)) {
                    Label("导出演唱", systemImage: "square.and.arrow.up")
                }
                Button("删除演唱", systemImage: "trash", role: .destructive) { deletingPerformance = performance }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(.secondary) }
                .accessibilityLabel("\(performance.title)演唱的更多操作")
        }
        .disabled(viewModel.recording.isBusy || viewModel.isProcessing || viewModel.isImporting)
        .padding(12).studioCard()
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
        LibraryBrowser.songs(viewModel.songs, query: songSearch, favoritesOnly: favoriteSongsOnly,
                             unseparatedOnly: onlyUnseparated, sort: songSort)
    }

    private var filteredAccompaniments: [LibrarySong] {
        LibraryBrowser.songs(viewModel.songs, query: accompanimentSearch, favoritesOnly: favoriteAccompanimentsOnly,
                             lyricsOnly: lyricsReadyOnly, sort: accompanimentSort, accompaniments: true)
    }

    private var filteredPerformances: [SingingPerformance] {
        LibraryBrowser.performances(viewModel.recording.performances, query: performanceSearch, sort: performanceSort)
    }

    private func browserToolbar(_ title: String, count: Int, sort: Binding<LibrarySortOrder>, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(title) · \(count)").font(.headline).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Menu {
                Picker("排序方式", selection: sort) {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                        Label(order.label, systemImage: order.symbol).tag(order)
                    }
                }
            } label: {
                Label(sort.wrappedValue.label, systemImage: "arrow.up.arrow.down")
                    .font(.caption.weight(.semibold)).padding(.vertical, 12)
            }
            .accessibilityLabel("\(title)排序，\(sort.wrappedValue.label)")
            .accessibilityIdentifier("library.sort.\(identifier)")
        }
    }

    private func filterPill(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 15).frame(minHeight: 44)
            .foregroundStyle(selected ? .white : StudioTheme.accent)
            .background(selected ? StudioTheme.accent : StudioTheme.blush.opacity(0.65), in: Capsule())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func importSongs() {
        viewModel.isSelectingLyrics = false
        viewModel.isImporterPresented = true
    }
}
