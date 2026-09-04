import Combine
import Foundation
import UIKit

struct UserAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class SeparationViewModel: ObservableObject {
    @Published var isImporterPresented = false
    @Published private(set) var selectedAudio: ImportedAudio?
    @Published private(set) var importedLyrics: ImportedLyrics?
    @Published var isSelectingLyrics = false
    @Published private(set) var result: SeparationResult?
    @Published private(set) var transcript: VocalTranscript?
    @Published private(set) var transcriptionErrorText: String?
    @Published private(set) var transcriptionStage: VocalTranscriptionStage?
    @Published private(set) var hasRequestedTranscription = false
    @Published private(set) var isImporting = false
    @Published private(set) var isSeparating = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var statusText = "导入歌曲，可同时选择对应歌词"
    @Published var alert: UserAlert?
    @Published private(set) var songs: [LibrarySong] = []
    @Published private(set) var selectedSongID: UUID?
    @Published private(set) var isLibraryAvailable = true
    let library: SongLibraryStore

    let playback = AudioPlaybackController()
    let recording: SingingRecordingController
    private var recordingChanges: AnyCancellable?

    private let engine: any StemSeparating
    private let metadataExtractor: any SongMetadataExtracting
    private let transcriptionCoordinator: PostSeparationTranscriptionCoordinator
    private var processingTask: Task<Void, Never>?

    init(
        engine: any StemSeparating = StemSeparationEngine(),
        transcriber: any VocalTranscribing = WhisperVocalTranscriber(),
        recording: SingingRecordingController? = nil,
        library: SongLibraryStore = SongLibraryStore(),
        metadataExtractor: any SongMetadataExtracting = SongMetadataExtractor()
    ) {
        self.engine = engine
        self.library = library
        self.metadataExtractor = metadataExtractor
        self.recording = recording ?? SingingRecordingController()
        transcriptionCoordinator = PostSeparationTranscriptionCoordinator(
            transcriber: transcriber
        )
        do {
            songs = try library.load()
        } catch {
            isLibraryAvailable = false
            alert = UserAlert(title: "无法读取歌曲库", message: "歌曲文件仍保留在本机，请重启后重试。\(error.localizedDescription)")
        }
        recordingChanges = self.recording.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isProcessing: Bool {
        isSeparating || isTranscribing
    }

    var canManageLibrary: Bool { isLibraryAvailable && !isImporting && !isProcessing && !recording.isBusy }
    var selectedSong: LibrarySong? { songs.first { $0.id == selectedSongID } }
    var separatedSongs: [LibrarySong] {
        songs.filter { $0.separation != nil }.sorted {
            ($0.separation?.createdAt ?? .distantPast) > ($1.separation?.createdAt ?? .distantPast)
        }
    }

    func selectSong(_ song: LibrarySong) {
        guard canManageLibrary, let current = songs.first(where: { $0.id == song.id }) else { return }
        playback.stop()
        selectedSongID = current.id
        selectedAudio = library.audio(for: current)
        importedLyrics = current.lyrics
        result = library.result(for: current)
        resetTranscription()
        transcript = current.transcript
        hasRequestedTranscription = transcript != nil
        statusText = result == nil ? "歌曲已就绪，可以开始分离" : "伴奏已准备好，可以开始唱歌"
        extractMetadataIfNeeded(for: current)
    }

    /// Older libraries have no metadata key. Inspect their managed source once on selection.
    private func extractMetadataIfNeeded(for song: LibrarySong) {
        guard song.metadata == nil else { return }
        isImporting = true
        statusText = "正在读取封面与歌词…"
        let library = library
        let extractor = metadataExtractor
        Task { [weak self] in
            guard let self else { return }
            defer { isImporting = false }
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    let extracted = await extractor.extract(from: library.audio(for: song).url)
                    return try library.applying(extracted, to: song)
                }.value
                do {
                    try updateSong(song.id) {
                        $0.metadata = updated.metadata
                        $0.lyrics = updated.lyrics
                    }
                } catch {
                    try? library.removeArtwork(for: updated)
                    throw error
                }
                if selectedSongID == song.id { importedLyrics = selectedSong?.lyrics }
                statusText = result == nil ? "歌曲已就绪，可以开始分离" : "伴奏已准备好，可以开始唱歌"
            } catch { present(error: error, title: "无法保存歌曲信息") }
        }
    }

    func renameSong(_ song: LibrarySong, title: String) {
        guard canManageLibrary else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            try updateSong(song.id) { $0.title = title }
            if selectedSongID == song.id, let current = selectedSong { selectSong(current) }
        } catch { present(error: error, title: "重命名失败") }
    }

    func deleteSong(_ song: LibrarySong, separationOnly: Bool) {
        guard canManageLibrary else { return }
        do {
            playback.stop()
            var updated = songs
            if separationOnly {
                guard let index = updated.firstIndex(where: { $0.id == song.id }) else { return }
                updated[index].separation = nil
                updated[index].transcript = nil
            } else {
                updated.removeAll { $0.id == song.id }
            }
            try library.save(updated)
            songs = updated
            if selectedSongID == song.id {
                if let current = selectedSong { selectSong(current) }
                else {
                    selectedSongID = nil
                    selectedAudio = nil
                    importedLyrics = nil
                    result = nil
                    resetTranscription()
                }
            }
            try library.removeFiles(for: song, includingSource: !separationOnly)
        } catch { present(error: error, title: "删除未完全完成") }
    }

    private func updateSong(_ id: UUID, change: (inout LibrarySong) -> Void) throws {
        guard let index = songs.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        var updated = songs
        change(&updated[index])
        try library.save(updated)
        songs = updated
    }

    var canStart: Bool {
        selectedAudio != nil && canManageLibrary
    }

    var canRetryTranscription: Bool {
        result != nil && !isImporting && !isProcessing && !recording.isBusy
    }

    var modelDownloadProgress: Double? {
        guard case .downloadingModel(let fraction) = transcriptionStage else {
            return nil
        }
        return fraction
    }

    func handleImport(_ importResult: Result<URL, Error>) {
        handleFilesImport(importResult.map { [$0] })
    }

    func handleFilesImport(_ importResult: Result<[URL], Error>) {
        guard canManageLibrary else { return }
        switch importResult {
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                present(error: error, title: "无法选择文件")
            }
        case .success(let urls):
            guard !urls.isEmpty else { return }
            let lyricsOnly = isSelectingLyrics
            isSelectingLyrics = false
            let lyricURLs = lyricsOnly ? urls : urls.filter {
                LyricsImportStore.supportedExtensions.contains($0.pathExtension.lowercased())
            }
            let audioURLs = lyricsOnly ? [] : urls.filter { !lyricURLs.contains($0) }
            guard lyricURLs.count <= 1, (lyricURLs.isEmpty || audioURLs.count <= 1),
                  (!audioURLs.isEmpty || (!lyricURLs.isEmpty && selectedAudio != nil)) else {
                alert = UserAlert(title: "请确认歌词对应的歌曲", message: "可一次导入多首歌曲；带歌词导入时，请选择一首歌曲和一份对应歌词。")
                return
            }
            isImporting = true
            statusText = "正在导入歌曲并读取封面与歌词…"
            if audioURLs.isEmpty { playback.pause() } else { playback.stop() }
            let library = library
            let extractor = metadataExtractor

            Task { [weak self] in
                guard let self else { return }
                do {
                    // Validate the whole batch before publishing it to the library.
                    let (additions, lyrics) = try await Task.detached(priority: .userInitiated) {
                        let lyrics = try lyricURLs.first.map { try LyricsImportStore.load($0) }
                        var audios: [ImportedAudio] = []
                        var additions: [LibrarySong] = []
                        do {
                            for url in audioURLs {
                                let audio = try AudioImportStore.persist(url, root: library.root)
                                audios.append(audio)
                                let extracted = await extractor.extract(from: audio.url)
                                additions.append(try library.applying(extracted, to: LibrarySong(audio: audio, lyrics: lyrics)))
                            }
                            return (additions, lyrics)
                        } catch {
                            for audio in audios { try? FileManager.default.removeItem(at: audio.url) }
                            for song in additions { try? library.removeArtwork(for: song) }
                            throw error
                        }
                    }.value
                    if let first = additions.first {
                        do { try library.save(additions + songs) }
                        catch {
                            for song in additions { try? library.removeFiles(for: song, includingSource: true) }
                            throw error
                        }
                        songs = additions + songs
                        selectedSongID = additions.first?.id
                        selectedAudio = library.audio(for: first)
                        result = nil
                        importedLyrics = first.lyrics
                        resetTranscription()
                    } else {
                        if let id = selectedSongID { try updateSong(id) { $0.lyrics = lyrics } }
                        importedLyrics = lyrics
                    }
                    statusText = result == nil ? "已导入，点击开始分离" : "歌词已更新，可以开始唱歌"
                } catch {
                    present(error: error, title: "导入失败")
                    if let selectedAudio {
                        statusText = "导入失败，仍可使用 \(selectedAudio.displayName)"
                    } else {
                        statusText = "请选择系统可解码的音频文件"
                    }
                }
                isImporting = false
            }
        }
    }

    func startSeparation() {
        guard let selectedAudio, canStart else { return }
        playback.stop()
        guard let songID = selectedSongID else { return }
        let previousSong = selectedSong
        resetTranscription()
        progress = 0
        isSeparating = true
        UIApplication.shared.isIdleTimerDisabled = true
        statusText = "正在准备…"

        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let separationResult = try await engine.separate(
                    sourceURL: selectedAudio.url,
                    outputRoot: library.separationsDirectory
                ) { [weak self] update in
                    await self?.apply(update)
                }
                do {
                    try Task.checkCancellation()
                    try updateSong(songID) {
                        $0.separation = SavedSeparation(separationResult)
                        $0.transcript = nil
                    }
                } catch {
                    var orphan = LibrarySong(audio: selectedAudio, lyrics: nil)
                    orphan.separation = SavedSeparation(separationResult)
                    try? library.removeFiles(for: orphan, includingSource: false)
                    throw error
                }
                result = self.selectedSong.flatMap { self.library.result(for: $0) }
                if let previousSong, previousSong.separation != nil {
                    try? library.removeFiles(for: previousSong, includingSource: false)
                }
                progress = 1
                statusText = "伴奏已准备好，可以开始唱歌"
            } catch is CancellationError {
                statusText = "已取消"
                progress = 0
            } catch {
                present(error: error, title: "分离失败")
                statusText = "处理未完成"
                progress = 0
            }
            isSeparating = false
            isTranscribing = false
            UIApplication.shared.isIdleTimerDisabled = false
            processingTask = nil
        }
    }

    func startTranscription() {
        guard let result, canRetryTranscription else { return }
        playback.stop()
        hasRequestedTranscription = true
        transcript = nil
        transcriptionErrorText = nil
        transcriptionStage = nil
        alert = nil
        isTranscribing = true
        UIApplication.shared.isIdleTimerDisabled = true
        statusText = "正在准备人声转写…"

        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let completedTranscript = try await transcriptionCoordinator.transcribe(
                    separationResult: result
                ) { [weak self] stage in
                    await self?.apply(stage)
                }
                try Task.checkCancellation()
                if let id = selectedSongID { try updateSong(id) { $0.transcript = completedTranscript } }
                transcript = completedTranscript
                statusText = "分离与转写完成"
            } catch is CancellationError {
                statusText = "分离完成，已取消转写"
            } catch {
                transcriptionErrorText = Self.errorMessage(error)
                present(
                    error: error,
                    title: error is TranscriptionModelManagerError
                        ? "模型准备失败"
                        : "转写失败"
                )
                statusText = "分离完成，转写未完成"
            }
            isTranscribing = false
            UIApplication.shared.isIdleTimerDisabled = false
            processingTask = nil
        }
    }

    func retryTranscription() {
        startTranscription()
    }

    func cancel() {
        processingTask?.cancel()
        if isPreparingTranscriptionModel {
            statusText = "正在取消转写模型准备…"
        } else if isTranscribing {
            statusText = "正在取消转写；当前推理步骤结束后停止…"
        } else {
            statusText = "正在取消；当前推理块结束后停止…"
        }
    }

    func cancelForBackground() {
        if !recording.isBusy, !isProcessing { playback.pause() }
        recording.handleBackground()
        guard isProcessing else { return }
        processingTask?.cancel()
        statusText = "应用已进入后台，正在停止并清理…"
    }

    func startSinging() {
        guard let result, !isImporting, !isProcessing, !recording.isBusy else { return }
        Task {
            await recording.start(result: result, lyrics: importedLyrics?.lyrics, playback: playback)
        }
    }

    func toggleKaraokePlayback() {
        guard let result, !isImporting, !isProcessing, !recording.isBusy else { return }
        do {
            try playback.toggle(result.accompanimentURL, vocalsURL: result.vocalsURL, vocalsEnabled: recording.vocalsEnabled)
        } catch {
            present(error: error, title: "无法播放")
        }
    }

    func togglePlayback(_ url: URL) {
        guard !isImporting, !isProcessing, !recording.isBusy else { return }
        do {
            try playback.toggle(url)
        } catch {
            present(error: error, title: "无法播放")
        }
    }

    func removeLyrics() {
        guard !isImporting, !isProcessing, !recording.isBusy else { return }
        do {
            if let id = selectedSongID { try updateSong(id) { $0.lyrics = nil } }
            importedLyrics = nil
        } catch { present(error: error, title: "无法移除歌词") }
    }

    private func apply(_ update: SeparationProgress) {
        progress = min(max(update.fraction, 0), 1)
        switch update.stage {
        case .preparingAudio:
            statusText = "正在解码并转换为 44.1 kHz…"
        case .loadingModel:
            statusText = "正在载入分离模型…"
        case .separating(let chunk, let total):
            statusText = "正在分离第 \(chunk) / \(total) 段"
        case .finalizing:
            statusText = "正在写入结果…"
        }
    }

    private func apply(_ stage: VocalTranscriptionStage) {
        transcriptionStage = stage
        switch stage {
        case .checkingModel:
            statusText = "正在检查本机转写模型…"
        case .downloadingModel(let fraction):
            statusText = "正在下载转写模型（\(Int(fraction * 100))%）…"
        case .verifyingModel:
            statusText = "正在校验转写模型…"
        case .prewarmingModel:
            statusText = "正在为本机优化转写模型（首次可能较慢）…"
        case .loadingModel:
            statusText = "正在载入转写模型…"
        case .transcribing:
            statusText = "正在将分离后的人声转为文本…"
        }
    }

    private func resetTranscription() {
        transcript = nil
        transcriptionErrorText = nil
        transcriptionStage = nil
        hasRequestedTranscription = false
    }

    private var isPreparingTranscriptionModel: Bool {
        switch transcriptionStage {
        case .checkingModel, .downloadingModel, .verifyingModel:
            return true
        case .prewarmingModel, .loadingModel, .transcribing, .none:
            return false
        }
    }

    private func present(error: Error, title: String) {
        alert = UserAlert(
            title: title,
            message: Self.errorMessage(error)
        )
    }

    private static func errorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }
}
