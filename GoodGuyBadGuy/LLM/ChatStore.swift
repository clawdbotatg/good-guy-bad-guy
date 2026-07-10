import Foundation
import UIKit

/// Owns the model lifecycle (download → load → chat) and the message list
/// the UI renders. The actual generation backend is an `LLMEngine`:
/// MLX on device, a mock in the simulator.
@Observable
@MainActor
final class ChatStore {
    enum ModelState: Equatable {
        case idle
        case downloading(Double)  // 0...1 fraction of the weights download
        case ready
        case failed(String)
    }

    private(set) var modelState: ModelState = .idle
    private(set) var messages: [ChatMessage] = []
    private(set) var isGenerating = false

    /// Which brain is selected, and which have finished downloading at least
    /// once (persisted, so the UI can show "downloaded" vs "download" and a
    /// re-select loads from cache instead of re-fetching).
    private(set) var currentModelID: String
    private(set) var downloadedModelIDs: Set<String>

    /// Two backends: the cloud classifier (default) and the on-device model.
    /// `engine` is whichever the selected brain routes to.
    private let cloudEngine: LLMEngine = CloudEngine()
    private let localEngine: LLMEngine
    private var engine: LLMEngine {
        BrainCatalog.isCloud(currentModelID) ? cloudEngine : localEngine
    }
    private var generationTask: Task<Void, Never>?

    /// Raw fraction reported by the loader, and a time-based sweep over it.
    /// The weights are one giant file, so the real fraction can sit near 1%
    /// for minutes; the sweep keeps the Brain's progress visibly alive.
    private var realFraction: Double = 0
    private var downloadStart: Date?
    private var sweepTask: Task<Void, Never>?

    private static let modelKey = "brain.currentModelID"
    private static let downloadedKey = "brain.downloadedModelIDs"

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Self.modelKey)
        currentModelID =
            (saved.flatMap { id in BrainCatalog.all.first { $0.id == id }?.id })
            ?? BrainCatalog.defaultID
        downloadedModelIDs = Set(defaults.stringArray(forKey: Self.downloadedKey) ?? [])

        #if targetEnvironment(simulator)
        localEngine = MockEngine()
        #else
        localEngine = MLXEngine()
        #endif
        configureEngine(for: currentModelID)
    }

    /// Point the selected brain's engine at the right model: a local brain sets
    /// the MLX repo id; a cloud brain sets the server model the classifier runs.
    private func configureEngine(for id: String) {
        let model = BrainCatalog.model(for: id)
        if model.isCloud {
            cloudEngine.setModel(model.serverModel ?? "claude")
        } else {
            localEngine.setModel(id)
        }
    }

    var availableModels: [BrainModel] { BrainCatalog.all }
    var currentModel: BrainModel { BrainCatalog.model(for: currentModelID) }
    var modelName: String { currentModel.name }

    func loadModel() async {
        guard modelState != .ready else { return }
        realFraction = 0
        downloadStart = Date()
        modelState = .downloading(0)
        startSweep()
        // If the screen auto-locks mid-download iOS suspends the app and the
        // download stalls, so keep the screen awake until the model is ready.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            stopSweep()
        }
        do {
            try await engine.load { fraction in
                self.realFraction = fraction
            }
            modelState = .ready
            markDownloaded(currentModelID)
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    /// Ticks the displayed download fraction: `max(real, time-based sweep)`,
    /// capped at 99% until the load actually completes.
    private func startSweep() {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = self.downloadStart.map { Date().timeIntervalSince($0) } ?? 0
                let sweep =
                    elapsed < 60
                    ? elapsed / 60 * 0.90
                    : 0.90 + min((elapsed - 60) / 300, 1) * 0.09
                let shown = min(max(self.realFraction, sweep), 0.99)
                if case .downloading = self.modelState {
                    self.modelState = .downloading(shown)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopSweep() {
        sweepTask?.cancel()
        sweepTask = nil
    }

    /// Switch brains: reload the model and start a fresh scan (a new brain
    /// shouldn't answer follow-ups about the old one's verdict).
    func selectModel(_ id: String) {
        guard id != currentModelID, !id.isEmpty, !isDownloading else { return }
        DebugLog.log("selectModel: \(currentModelID) -> \(id)")
        currentModelID = id
        UserDefaults.standard.set(id, forKey: Self.modelKey)
        clear()
        configureEngine(for: id)
        modelState = .idle
        Task { await loadModel() }
    }

    var isDownloading: Bool {
        if case .downloading = modelState { return true }
        return false
    }

    /// Cloud needs no download; treat it as always "ready to use".
    func isDownloaded(_ id: String) -> Bool {
        BrainCatalog.isCloud(id) || downloadedModelIDs.contains(id)
    }

    private func markDownloaded(_ id: String) {
        downloadedModelIDs.insert(id)
        UserDefaults.standard.set(
            Array(downloadedModelIDs), forKey: Self.downloadedKey)
    }

    func send(_ text: String, image: UIImage? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelState == .ready, !isGenerating, !trimmed.isEmpty || image != nil else { return }
        let prompt = trimmed.isEmpty ? "Good guy or bad guy?" : trimmed

        messages.append(ChatMessage(role: .user, text: prompt, image: image))
        messages.append(ChatMessage(role: .assistant, text: ""))
        let index = messages.count - 1
        isGenerating = true
        let ciImage = image.flatMap { CIImage(image: $0) }
        DebugLog.log("send: \"\(prompt)\"\(image != nil ? " +image" : "")")

        generationTask = Task {
            do {
                for try await chunk in engine.respond(to: prompt, image: ciImage) {
                    messages[index].text += chunk
                }
                DebugLog.log("reply done (\(messages[index].text.count) chars)")
            } catch is CancellationError {
                DebugLog.log("generation cancelled by user")
            } catch {
                DebugLog.log("generation error: \(error)")
                messages[index].text += "\n\n⚠️ \(error.localizedDescription)"
            }
            isGenerating = false
        }
    }

    func stopGenerating() {
        generationTask?.cancel()
    }

    /// New conversation: drop UI messages and the engine's history state.
    func clear() {
        stopGenerating()
        messages.removeAll()
        engine.reset()
    }
}
