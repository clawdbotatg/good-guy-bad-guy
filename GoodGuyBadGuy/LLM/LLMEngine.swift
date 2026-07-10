import CoreImage
import Foundation

/// Abstraction over the text-generation backend so the app runs everywhere:
/// on device it's MLX + Qwen (`MLXEngine`); in the iOS Simulator — where MLX
/// has no Metal GPU — it's a canned `MockEngine`, keeping the full UI
/// testable in automated simulator runs.
@MainActor
protocol LLMEngine {
    var modelName: String { get }
    /// Download/prepare the model. `onProgress` reports 0...1 of the download.
    func load(onProgress: @escaping @MainActor (Double) -> Void) async throws
    /// Drop conversation history (new chat).
    func reset()
    /// Stream a reply to `prompt`, continuing the current conversation.
    /// `image` attaches a photo for vision models.
    func respond(to prompt: String, image: CIImage?) -> AsyncThrowingStream<String, Error>
}

/// Simulator/test stand-in: fakes a short download, then streams a canned
/// reply word-by-word so streaming UI, scrolling, stop, etc. are exercised.
@MainActor
final class MockEngine: LLMEngine {
    let modelName = "MockEngine (simulator)"

    func load(onProgress: @escaping @MainActor (Double) -> Void) async throws {
        for step in 1...20 {
            try await Task.sleep(for: .milliseconds(100))
            onProgress(Double(step) / 20)
        }
    }

    func reset() {}

    func respond(to prompt: String, image: CIImage?) -> AsyncThrowingStream<String, Error> {
        let reply =
            image != nil
            ? "<think>Mock verdict for the simulator.</think>"
                + "VERDICT: BAD GUY\n\nBlack widow spider (Latrodectus mactans) — mock reply; "
                + "the real model needs a device GPU. Glossy black body with a red hourglass "
                + "on the underside. Keep your distance, and shake out shoes or gloves that "
                + "sat outside."
            : "This is the mock simulator engine (MLX needs a real device's GPU). "
                + "You said: “\(prompt)”. Attach a photo of a critter — on an iPhone the real "
                + "model answers with a GOOD GUY / BAD GUY / CAUTION verdict."
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                    guard !Task.isCancelled else { break }
                    continuation.yield(String(word) + " ")
                    try? await Task.sleep(for: .milliseconds(40))
                }
                continuation.finish()
            }
        }
    }
}
