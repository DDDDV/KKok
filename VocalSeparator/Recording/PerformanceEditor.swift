import Combine
import Foundation

@MainActor
final class PerformanceEditor: ObservableObject {
    enum Operation { case preview, save }
    @Published private(set) var performance: SingingPerformance
    @Published var settings: PerformanceMixSettings {
        didSet {
            if oldValue != settings {
                playback.pause()
                errorText = nil
                didSave = false
            }
        }
    }
    @Published private(set) var operation: Operation?
    @Published private(set) var errorText: String?
    @Published private(set) var didSave = false
    let store: PerformanceStore
    let playback: AudioPlaybackController
    private let onSave: (SingingPerformance) -> Void
    private var preview: RenderedPerformance?
    private var worker: Task<RenderedPerformance, Error>?
    private var saveWorker: Task<SingingPerformance, Error>?
    private var operationID: UUID?
    private let previewDirectory: URL

    var canEdit: Bool { store.canEdit(performance) }
    var isBusy: Bool { operation != nil }
    var hasChanges: Bool { settings != performance.settings }
    var savedURL: URL { store.mixURL(performance) }
    var auditionURL: URL? {
        if preview?.settings == settings { return preview?.url }
        return hasChanges ? nil : savedURL
    }

    init(performance: SingingPerformance, store: PerformanceStore, playback: AudioPlaybackController,
         onSave: @escaping (SingingPerformance) -> Void = { _ in }) {
        self.performance = performance
        self.settings = performance.settings
        self.store = store
        self.playback = playback
        self.onSave = onSave
        previewDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PerformanceEdit-\(UUID().uuidString)")
    }

    func load() {
        do { try playback.load(savedURL) }
        catch { errorText = error.localizedDescription }
    }

    func audition() async {
        guard !isBusy else { return }
        errorText = nil
        let time = playback.currentTime
        if let url = auditionURL {
            do { try playback.toggle(url) }
            catch { errorText = error.localizedDescription }
            return
        }
        playback.pause()
        let id = begin(.preview)
        defer { end(id) }
        do {
            let render = try await renderCurrentSettings()
            guard operationID == id else { return }
            try playback.load(render.url)
            playback.seek(to: time)
            try playback.play()
        } catch {
            if operationID == id { errorText = "试听失败：\(error.localizedDescription)" }
        }
    }

    func save() async {
        guard !isBusy, hasChanges, canEdit else { return }
        errorText = nil
        let time = playback.currentTime
        playback.pause()
        let id = begin(.save)
        defer { end(id) }
        do {
            let rendered = try await renderCurrentSettings()
            guard operationID == id else { return }
            let store = store
            let previous = performance
            let task = Task.detached(priority: .userInitiated) { try store.save(rendered, replacing: previous) }
            saveWorker = task
            let saved = try await task.value
            // Publish a completed disk commit even if the view disappeared meanwhile.
            performance = saved
            onSave(saved)
            guard operationID == id else { return }
            didSave = true
            do {
                try playback.load(store.mixURL(saved))
                playback.seek(to: time)
            } catch {
                playback.stop()
                errorText = "调整已保存，但暂时无法回放：\(error.localizedDescription)"
            }
            clearPreview()
        } catch {
            if operationID == id { errorText = "保存调整失败：\(error.localizedDescription)" }
        }
    }

    func close() {
        operationID = nil
        worker?.cancel()
        saveWorker?.cancel()
        playback.stop()
        let renderTask = worker
        let commitTask = saveWorker
        let directory = previewDirectory
        // Wait for cancelled file writers before removing their scratch files.
        Task.detached {
            _ = await renderTask?.result
            _ = await commitTask?.result
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func begin(_ value: Operation) -> UUID {
        let id = UUID()
        operationID = id
        operation = value
        return id
    }

    private func end(_ id: UUID) {
        guard operationID == id else { return }
        operation = nil
        worker = nil
        saveWorker = nil
        operationID = nil
    }

    private func renderCurrentSettings() async throws -> RenderedPerformance {
        if let preview, preview.settings == settings { return preview }
        playback.stop()
        clearPreview()
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        let output = previewDirectory.appendingPathComponent("试听.wav")
        let store = store
        let performance = performance
        let settings = settings
        let task = Task.detached(priority: .userInitiated) {
            try store.render(performance, settings: settings, to: output)
        }
        worker = task
        let result = try await task.value
        try Task.checkCancellation()
        preview = result
        return result
    }

    private func clearPreview() {
        if let preview { try? FileManager.default.removeItem(at: preview.url) }
        preview = nil
    }
}
