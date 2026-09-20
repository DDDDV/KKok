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
    @State private var isShowingSettings = false
    @State private var exportRequest: AudioExportRequest?
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
                .tabItem { Label(String(localized: "Songs"), systemImage: "square.stack.fill") }.tag(LibraryTab.songs)
            libraryPage(.accompaniments)
                .tabItem { Label(String(localized: "Backing Tracks"), systemImage: "waveform") }.tag(LibraryTab.accompaniments)
            libraryPage(.performances)
                .tabItem { Label(String(localized: "My Recordings"), systemImage: "mic.fill") }.tag(LibraryTab.performances)
        }
        .tint(StudioTheme.accent)
        .preferredColorScheme(.light)
        .fileImporter(isPresented: $viewModel.isImporterPresented, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            viewModel.handleFilesImport(result) {
                isShowingSong = true
            }
        }
        .alert(item: Binding(get: { isShowingSong ? nil : viewModel.alert }, set: { viewModel.alert = $0 })) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text(String(localized: "OK"))))
        }
        .sheet(isPresented: $isShowingSettings) { SettingsView() }
        .sheet(item: $exportRequest) { AudioExportSheet(request: $0) }
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
        .alert(renamingPerformance == nil ? String(localized: "Rename Song") : String(localized: "Rename Recording"), isPresented: Binding(
            get: { renamingSong != nil || renamingPerformance != nil },
            set: { if !$0 { renamingSong = nil; renamingPerformance = nil } }
        )) {
            TextField(String(localized: "Name"), text: $editedTitle)
            Button(String(localized: "Save")) {
                if let song = renamingSong { viewModel.renameSong(song, title: editedTitle) }
                if let performance = renamingPerformance { viewModel.recording.rename(performance, title: editedTitle) }
                renamingSong = nil
                renamingPerformance = nil
            }
            .disabled(editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(String(localized: "Cancel"), role: .cancel) { renamingSong = nil; renamingPerformance = nil }
        }
        .confirmationDialog(deletesSeparationOnly ? String(localized: "Delete separated tracks?") : String(localized: "Delete this song?"), isPresented: Binding(
            get: { deletingSong != nil }, set: { if !$0 { deletingSong = nil } }
        ), titleVisibility: .visible) {
            Button(deletesSeparationOnly ? String(localized: "Delete Backing Track and Vocals") : String(localized: "Delete Song and Separated Tracks"), role: .destructive) {
                if let song = deletingSong { viewModel.deleteSong(song, separationOnly: deletesSeparationOnly) }
                deletingSong = nil
            }
        } message: {
            Text(deletesSeparationOnly ? String(localized: "The imported original and saved recordings will be kept. You can separate the song again.") : String(localized: "This will delete the local original, its lyrics, and separated tracks. Saved recordings will be kept."))
        }
        .confirmationDialog(String(localized: "Delete this recording?"), isPresented: Binding(
            get: { deletingPerformance != nil }, set: { if !$0 { deletingPerformance = nil } }
        ), titleVisibility: .visible) {
            Button(String(localized: "Delete Recording"), role: .destructive) {
                if let performance = deletingPerformance {
                    viewModel.recording.delete(performance, playback: viewModel.playback)
                }
                deletingPerformance = nil
            }
        } message: { Text(String(localized: "This will delete this performance and its raw recording. The song and backing track will be kept.")) }
        .confirmationDialog(String(localized: "Discard the unsaved recording?"), isPresented: $isDiscardingRecording, titleVisibility: .visible) {
            Button(String(localized: "Discard Recording"), role: .destructive) { viewModel.recording.discardPending() }
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
                        Label(String(localized: "A recording is waiting to be saved · Review"), systemImage: "arrow.clockwise.circle")
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
                Label(String(localized: "Sing Freely · Sing from the heart"), systemImage: "heart.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(StudioTheme.accent)
                Text(tab == .songs ? String(localized: "Songs") : tab == .accompaniments ? String(localized: "Backing Tracks") : String(localized: "My Recordings"))
                    .font(.largeTitle.bold()).tracking(-1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 12)
            Button { isShowingSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44).background(.white.opacity(0.9), in: Circle())
                    .overlay { Circle().stroke(StudioTheme.border.opacity(0.5), lineWidth: 1) }
            }
            .accessibilityLabel(String(localized: "Settings")).accessibilityIdentifier("library.settings")
        }
    }

    private var songsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioHeroCard(eyebrow: String(localized: "YOUR PERSONAL PLAYLIST"), title: String(localized: "Songs you love.\nSing them freely."),
                           subtitle: String(localized: "Songs: \(viewModel.songs.count) · Backing tracks ready: \(viewModel.separatedSongs.count)")) {
                Button(action: importSongs) {
                    Label(viewModel.isImporting ? String(localized: "Importing…") : String(localized: "Import Songs"), systemImage: "plus")
                }
                .buttonStyle(StudioHeroButtonStyle())
                .disabled(!viewModel.canManageLibrary).accessibilityIdentifier("library.import")
            }
            StudioSearchField(text: $songSearch, placeholder: String(localized: "Search your songs"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterPill(String(localized: "All"), symbol: "music.note.list", selected: !onlyUnseparated && !favoriteSongsOnly) {
                        onlyUnseparated = false; favoriteSongsOnly = false
                    }
                    filterPill(String(localized: "Favorites"), symbol: "heart", selected: favoriteSongsOnly) { favoriteSongsOnly.toggle() }
                        .accessibilityIdentifier("library.songs.favorites")
                    filterPill(String(localized: "Not Separated"), symbol: "waveform.path", selected: onlyUnseparated) { onlyUnseparated.toggle() }
                }
            }
            browserToolbar(String(localized: "My Songs"), count: filteredSongs.count, sort: $songSort, identifier: "songs")
            if !viewModel.isLibraryAvailable {
                StudioEmptyState(symbol: "externaldrive.badge.exclamationmark", title: String(localized: "The song library is unavailable"),
                                 message: String(localized: "Your files are still on this device. Restart the app and try again."))
            } else if viewModel.songs.isEmpty {
                StudioEmptyState(symbol: "music.note.list", title: String(localized: "Make room for your first song"),
                                 message: String(localized: "Import multiple audio files from Files,\nor add a song together with its LRC lyrics."))
            } else if filteredSongs.isEmpty {
                StudioEmptyState(symbol: favoriteSongsOnly ? "heart" : "magnifyingglass", title: String(localized: "No songs here yet"),
                                 message: String(localized: "Tap the heart next to a song to add it to Favorites, or try other filters."),
                                 actionTitle: String(localized: "Show All Songs"), action: {
                    songSearch = ""; favoriteSongsOnly = false; onlyUnseparated = false
                })
            } else {
                LazyVStack(spacing: 10) { ForEach(filteredSongs) { song in songRow(song, separated: false) } }
            }
            Label(String(localized: "Songs and recordings stay on this device"), systemImage: "internaldrive")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 4)
        }
    }

    private var accompanimentsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioHeroCard(eyebrow: String(localized: "THE STAGE IS YOURS"), title: String(localized: "Your song.\nYour turn."),
                           subtitle: String(localized: "Backing tracks: \(viewModel.separatedSongs.count) · Synced lyrics ready: \(viewModel.separatedSongs.filter { $0.lyrics != nil }.count)")) {
                Button {
                    if viewModel.selectRandomAccompaniment(from: filteredAccompaniments) { isShowingStage = true }
                } label: { Label(String(localized: "Surprise Me"), systemImage: "shuffle") }
                    .buttonStyle(StudioHeroButtonStyle())
                    .disabled(!viewModel.canManageLibrary || filteredAccompaniments.isEmpty)
                    .accessibilityHint(String(localized: "Choose a random backing track from the current results and open the singing screen"))
                    .accessibilityIdentifier("library.randomSing")
            }
            StudioSearchField(text: $accompanimentSearch, placeholder: String(localized: "Search separated songs"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterPill(String(localized: "All"), symbol: "waveform", selected: !favoriteAccompanimentsOnly && !lyricsReadyOnly) {
                        favoriteAccompanimentsOnly = false; lyricsReadyOnly = false
                    }
                    filterPill(String(localized: "Favorites"), symbol: "heart", selected: favoriteAccompanimentsOnly) { favoriteAccompanimentsOnly.toggle() }
                    filterPill(String(localized: "Lyrics Ready"), symbol: "text.quote", selected: lyricsReadyOnly) { lyricsReadyOnly.toggle() }
                        .accessibilityIdentifier("library.lyricsReady")
                }
            }
            browserToolbar(String(localized: "Ready to Sing"), count: filteredAccompaniments.count, sort: $accompanimentSort, identifier: "accompaniments")
            if viewModel.separatedSongs.isEmpty {
                StudioEmptyState(symbol: "waveform.path", title: String(localized: "Your backing tracks start here"),
                                 message: String(localized: "Separate vocals and backing tracks in Songs.\nWhen ready, come here to sing."),
                                 actionTitle: String(localized: "Go to Songs"), action: { selectedTab = .songs })
            } else if filteredAccompaniments.isEmpty {
                StudioEmptyState(symbol: "magnifyingglass", title: String(localized: "No matching backing tracks"),
                                 message: String(localized: "Try other keywords, or clear the Favorites and lyrics filters."),
                                 actionTitle: String(localized: "Show All Backing Tracks"), action: {
                    accompanimentSearch = ""; favoriteAccompanimentsOnly = false; lyricsReadyOnly = false
                })
            } else {
                LazyVStack(spacing: 10) { ForEach(filteredAccompaniments) { song in songRow(song, separated: true) } }
            }
        }
    }

    private var performancesContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioHeroCard(eyebrow: String(localized: "EVERY VOICE IS WORTH KEEPING"), title: String(localized: "Your voice.\nYour creation."),
                           subtitle: String(localized: "Recordings: \(viewModel.recording.performances.count) · Total time: \(StudioTheme.duration(viewModel.recording.performances.reduce(0) { $0 + $1.duration }))")) {
                Button { selectedTab = .accompaniments } label: { Label(String(localized: "Record a Song"), systemImage: "mic.badge.plus") }
                    .buttonStyle(StudioHeroButtonStyle())
            }
            if viewModel.recording.state == .needsRecovery { recoveryCard }
            if viewModel.recording.state == .mixing {
                ProgressView(String(localized: "Saving recording…")).frame(maxWidth: .infinity).padding(20).studioCard()
            }
            if let notice = viewModel.recording.notice {
                Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            if let error = viewModel.recording.errorText {
                Text(error).font(.caption).foregroundStyle(StudioTheme.accent)
            }
            StudioSearchField(text: $performanceSearch, placeholder: String(localized: "Search my recordings"))
            browserToolbar(String(localized: "My Performances"), count: filteredPerformances.count, sort: $performanceSort, identifier: "performances")
            if viewModel.recording.performances.isEmpty {
                StudioEmptyState(symbol: "mic.badge.plus", title: String(localized: "Capture your first performance"),
                                 message: String(localized: "Choose a backing track and start singing.\nYour performance will be saved here automatically."))
            } else if filteredPerformances.isEmpty {
                StudioEmptyState(symbol: "magnifyingglass", title: String(localized: "No recordings found"), message: String(localized: "Try searching for another recording name."),
                                 actionTitle: String(localized: "Show All Recordings"), action: { performanceSearch = "" })
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
                            Text("\(StudioTheme.duration(result.duration)) · \(song.lyrics == nil ? String(localized: "Add lyrics") : String(localized: "Lyrics Ready"))")
                                .font(.caption).foregroundStyle(.secondary)
                            if song.isFavorite == true {
                                Label(String(localized: "In Favorites"), systemImage: "heart.fill").font(.caption2).foregroundStyle(StudioTheme.accent)
                            }
                        } else {
                            Text(song.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(song.separation == nil ? String(localized: "Not Separated") : String(localized: "Backing Track Ready"))
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
                }.accessibilityLabel(String(localized: "Sing \(song.title)"))
                    .foregroundStyle(StudioTheme.accent)
            } else {
                Button { viewModel.toggleFavorite(song) } label: {
                    Image(systemName: song.isFavorite == true ? "heart.fill" : "heart")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(song.isFavorite == true
                    ? String(localized: "Remove \(song.title) from Favorites")
                    : String(localized: "Add \(song.title) to Favorites"))
                .accessibilityIdentifier("library.favorite.\(song.id)")
                .foregroundStyle(StudioTheme.accent)
            }
            Menu {
                Button(String(localized: "View Song"), systemImage: "music.note") { viewModel.selectSong(song); isShowingSong = true }
                Button(song.isFavorite == true ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"), systemImage: song.isFavorite == true ? "heart.slash" : "heart") {
                    viewModel.toggleFavorite(song)
                }
                Button(String(localized: "Rename"), systemImage: "pencil") { editedTitle = song.title; renamingSong = song }
                if let result = viewModel.library.result(for: song) {
                    Button(String(localized: "Export Backing Track"), systemImage: "square.and.arrow.up") {
                        exportRequest = AudioExportRequest(sourceURL: result.accompanimentURL, title: song.title + String(localized: "-Backing Track"))
                    }
                    Button(String(localized: "Export Vocals"), systemImage: "person.wave.2") {
                        exportRequest = AudioExportRequest(sourceURL: result.vocalsURL, title: song.title + String(localized: "-Vocals"))
                    }
                }
                Button(separated ? String(localized: "Delete Separated Tracks") : String(localized: "Delete Song"), systemImage: "trash", role: .destructive) {
                    deletesSeparationOnly = separated
                    deletingSong = song
                }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(.secondary) }
                .accessibilityLabel(String(localized: "More actions for \(song.title)"))
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
                        Text(String(localized: "\(StudioTheme.duration(performance.duration)) · Listen and edit"))
                            .font(.caption2).foregroundStyle(StudioTheme.accent)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(StudioTheme.accent)
                        .frame(width: 44, height: 44)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button(String(localized: "Listen and Edit"), systemImage: "slider.horizontal.3") { reviewingPerformance = performance }
                Button(String(localized: "Rename Performance"), systemImage: "pencil") { editedTitle = performance.title; renamingPerformance = performance }
                Button(String(localized: "Export Recording"), systemImage: "square.and.arrow.up") {
                    exportRequest = AudioExportRequest(sourceURL: viewModel.recording.store.mixURL(performance),
                                                       title: performance.title + String(localized: "-My Recording"))
                }
                Button(String(localized: "Delete Recording"), systemImage: "trash", role: .destructive) { deletingPerformance = performance }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(.secondary) }
                .accessibilityLabel(String(localized: "More actions for the recording of \(performance.title)"))
        }
        .disabled(viewModel.recording.isBusy || viewModel.isProcessing || viewModel.isImporting)
        .padding(12).studioCard()
    }

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(String(localized: "A recording is waiting to be saved"), systemImage: "arrow.clockwise.circle").font(.headline)
            Text(String(localized: "Your raw recording has been kept. You can try saving the performance again.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Retry Saving"), action: viewModel.recording.retrySaving).buttonStyle(PrimaryActionButtonStyle())
                Button(String(localized: "Discard"), role: .destructive) { isDiscardingRecording = true }.buttonStyle(SecondaryActionButtonStyle())
            }
        }.padding(18).studioCard()
    }

    private var processingDock: some View {
        HStack(spacing: 12) {
            ProgressView().tint(StudioTheme.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(viewModel.selectedSong?.title ?? String(localized: "Importing song")).font(.subheadline.bold()).lineLimit(1)
                Text(viewModel.statusText).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                if viewModel.isSeparating { ProgressView(value: viewModel.progress).tint(StudioTheme.accent) }
            }
            Spacer(minLength: 0)
            if viewModel.isProcessing { Button(String(localized: "Cancel"), action: viewModel.cancel).font(.caption.bold()) }
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
                Picker(String(localized: "Sort By"), selection: sort) {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                        Label(order.label, systemImage: order.symbol).tag(order)
                    }
                }
            } label: {
                Label(sort.wrappedValue.label, systemImage: "arrow.up.arrow.down")
                    .font(.caption.weight(.semibold)).padding(.vertical, 12)
            }
            .accessibilityLabel(String(localized: "Sort \(title), \(sort.wrappedValue.label)"))
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
