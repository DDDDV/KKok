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
    @Published private(set) var result: SeparationResult?
    @Published private(set) var isImporting = false
    @Published private(set) var isProcessing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var statusText = "选择一首 MP3 开始"
    @Published var alert: UserAlert?

    let playback = AudioPlaybackController()

    private let engine = StemSeparationEngine()
    private var separationTask: Task<Void, Never>?

    init() {
        // Results are intentionally session-scoped. Clear stale/partial jobs
        // left by an earlier process termination before accepting new work.
        try? AudioImportStore.resetManagedStorage()
    }

    var canStart: Bool {
        selectedAudio != nil && !isImporting && !isProcessing
    }

    func handleImport(_ importResult: Result<URL, Error>) {
        switch importResult {
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                present(error: error, title: "无法选择文件")
            }
        case .success(let externalURL):
            isImporting = true
            statusText = "正在复制所选文件…"
            playback.stop()
            let previousAudio = selectedAudio
            let previousResult = result

            Task { [weak self] in
                guard let self else { return }
                do {
                    let imported = try await Task.detached(priority: .userInitiated) {
                        try AudioImportStore.persist(externalURL)
                    }.value
                    if let previousAudio { try? AudioImportStore.remove(previousAudio) }
                    if let previousResult { try? OutputStore.remove(previousResult) }
                    selectedAudio = imported
                    result = nil
                    statusText = "已选择，等待开始"
                } catch {
                    present(error: error, title: "导入失败")
                    if let selectedAudio {
                        statusText = "导入失败，仍可使用 \(selectedAudio.displayName)"
                    } else {
                        statusText = "请选择有效的 MP3 文件"
                    }
                }
                isImporting = false
            }
        }
    }

    func startSeparation() {
        guard let selectedAudio, !isProcessing else { return }
        playback.stop()
        if let result { try? OutputStore.remove(result) }
        result = nil
        progress = 0
        isProcessing = true
        UIApplication.shared.isIdleTimerDisabled = true
        statusText = "正在准备…"

        separationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let separationResult = try await engine.separate(
                    sourceURL: selectedAudio.url,
                    outputRoot: OutputStore.separationsDirectory()
                ) { [weak self] update in
                    await self?.apply(update)
                }
                result = separationResult
                progress = 1
                statusText = "分离完成"
            } catch is CancellationError {
                statusText = "已取消"
                progress = 0
            } catch {
                present(error: error, title: "分离失败")
                statusText = "处理未完成"
                progress = 0
            }
            isProcessing = false
            UIApplication.shared.isIdleTimerDisabled = false
            separationTask = nil
        }
    }

    func cancel() {
        separationTask?.cancel()
        statusText = "正在取消；当前推理块结束后停止…"
    }

    func cancelForBackground() {
        guard isProcessing else { return }
        separationTask?.cancel()
        statusText = "应用已进入后台，正在停止并清理…"
    }

    func togglePlayback(_ url: URL) {
        do {
            try playback.toggle(url)
        } catch {
            present(error: error, title: "无法播放")
        }
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

    private func present(error: Error, title: String) {
        alert = UserAlert(
            title: title,
            message: (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        )
    }
}
