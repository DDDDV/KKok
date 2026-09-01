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
    @Published private(set) var transcript: VocalTranscript?
    @Published private(set) var transcriptionErrorText: String?
    @Published private(set) var transcriptionStage: VocalTranscriptionStage?
    @Published private(set) var isImporting = false
    @Published private(set) var isSeparating = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var statusText = "选择一首 MP3 开始"
    @Published var alert: UserAlert?

    let playback = AudioPlaybackController()

    private let engine: any StemSeparating
    private let transcriptionCoordinator: PostSeparationTranscriptionCoordinator
    private var processingTask: Task<Void, Never>?

    init(
        engine: any StemSeparating = StemSeparationEngine(),
        transcriber: any VocalTranscribing = WhisperVocalTranscriber()
    ) {
        self.engine = engine
        transcriptionCoordinator = PostSeparationTranscriptionCoordinator(
            transcriber: transcriber
        )
        // Results are intentionally session-scoped. Clear stale/partial jobs
        // left by an earlier process termination before accepting new work.
        try? AudioImportStore.resetManagedStorage()
    }

    var isProcessing: Bool {
        isSeparating || isTranscribing
    }

    var canStart: Bool {
        selectedAudio != nil && !isImporting && !isProcessing
    }

    var canRetryTranscription: Bool {
        result != nil && !isImporting && !isProcessing
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
                    resetTranscription()
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
                    outputRoot: OutputStore.separationsDirectory()
                ) { [weak self] update in
                    await self?.apply(update)
                }
                result = separationResult
                progress = 1
                isSeparating = false
                isTranscribing = true
                statusText = "分离完成，正在准备人声转写…"

                do {
                    let completedTranscript = try await transcriptionCoordinator.transcribe(
                        separationResult: separationResult
                    ) { [weak self] stage in
                        await self?.apply(stage)
                    }
                    try Task.checkCancellation()
                    transcript = completedTranscript
                    transcriptionErrorText = nil
                    statusText = "分离与转写完成"
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    transcriptionErrorText = Self.errorMessage(error)
                    present(error: error, title: "转写失败")
                    statusText = "分离完成，转写未完成"
                }
            } catch is CancellationError {
                if result == nil {
                    statusText = "已取消"
                    progress = 0
                } else {
                    statusText = "分离完成，已取消转写"
                }
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

    func retryTranscription() {
        guard let result, canRetryTranscription else { return }
        playback.stop()
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
                transcript = completedTranscript
                statusText = "分离与转写完成"
            } catch is CancellationError {
                statusText = "分离完成，已取消转写"
            } catch {
                transcriptionErrorText = Self.errorMessage(error)
                present(error: error, title: "转写失败")
                statusText = "分离完成，转写未完成"
            }
            isTranscribing = false
            UIApplication.shared.isIdleTimerDisabled = false
            processingTask = nil
        }
    }

    func cancel() {
        processingTask?.cancel()
        if isTranscribing {
            statusText = "正在取消转写；当前推理步骤结束后停止…"
        } else {
            statusText = "正在取消；当前推理块结束后停止…"
        }
    }

    func cancelForBackground() {
        guard isProcessing else { return }
        processingTask?.cancel()
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

    private func apply(_ stage: VocalTranscriptionStage) {
        transcriptionStage = stage
        switch stage {
        case .checkingBundledModel:
            statusText = "正在检查应用内置的转写模型…"
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
