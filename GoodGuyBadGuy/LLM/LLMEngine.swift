import CoreImage
import Foundation

/// Abstraction over the generation backend so the app runs everywhere:
/// on device it's MLX + Qwen (`MLXEngine`); in the iOS Simulator — where MLX
/// has no Metal GPU — it's a canned `MockEngine`, keeping the full UI
/// testable in automated simulator runs.
@MainActor
protocol LLMEngine {
    var modelName: String { get }
    /// Download/prepare the model. `onProgress` reports 0...1 of the download.
    func load(onProgress: @escaping @MainActor (Double) -> Void) async throws
    /// Drop conversation history (new identification).
    func reset()
    /// With an `image`: identify it and stream the composed verdict.
    /// Without: answer a text follow-up about the last verdict.
    func respond(to prompt: String, image: CIImage?) -> AsyncThrowingStream<String, Error>
}

/// Simulator/test stand-in: MLX needs a real GPU, so the vision stage is
/// faked. Everything downstream is the real thing — the canned identification
/// goes through the same `DangerTable` the device uses, which makes the
/// simulator a genuine regression test for the verdict logic. The stand-in
/// species is the daylily, because the model itself once called it "safe for
/// cats" and the table must override that to BAD GUY.
@MainActor
final class MockEngine: LLMEngine {
    let modelName = "MockEngine (simulator)"

    private static let cannedIdentification = """
        CATEGORY: plant
        ID: Daylily (Hemerocallis)
        FEATURES: orange trumpet-shaped flower with six petals and strap-like leaves
        """

    func load(onProgress: @escaping @MainActor (Double) -> Void) async throws {
        for step in 1...20 {
            try await Task.sleep(for: .milliseconds(100))
            onProgress(Double(step) / 20)
        }
    }

    func reset() {}

    func respond(to prompt: String, image: CIImage?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                guard image != nil else {
                    continuation.yield(
                        "Mock simulator engine (MLX needs a real device's GPU). "
                            + "You asked: “\(prompt)”. On an iPhone the on-device model answers "
                            + "follow-ups here.")
                    continuation.finish()
                    return
                }
                // Pretend the vision stage took a moment, then run the real
                // verdict pipeline over its output.
                try? await Task.sleep(for: .milliseconds(900))
                continuation.yield(DangerTable.verdict(modelText: Self.cannedIdentification).text)
                continuation.finish()
            }
        }
    }
}
