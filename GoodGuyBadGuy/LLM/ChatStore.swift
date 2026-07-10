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

    private let engine: LLMEngine
    private var generationTask: Task<Void, Never>?

    init() {
        #if targetEnvironment(simulator)
        engine = MockEngine()
        #else
        engine = MLXEngine()
        #endif
    }

    var modelName: String { engine.modelName }

    func loadModel() async {
        guard modelState != .ready else { return }
        modelState = .downloading(0)
        // If the screen auto-locks mid-download iOS suspends the app and the
        // download stalls, so keep the screen awake until the model is ready.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            try await engine.load { fraction in
                self.modelState = .downloading(fraction)
            }
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
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
