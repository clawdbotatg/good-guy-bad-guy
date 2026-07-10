#if !targetEnvironment(simulator)

import CoreImage
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Real on-device backend: downloads the model from Hugging Face once,
/// then runs inference on the GPU via MLX.
@MainActor
final class MLXEngine: LLMEngine {
    /// Swap the model by pointing at any entry in `LLMRegistry` (text-only),
    /// `VLMRegistry` (vision), or any mlx-community repo id — linking MLXVLM
    /// makes the shared loader route vision models automatically.
    /// Qwen3-VL-8B-4bit (5.8 GB of weights) LOADS on a 12 GB iPhone 17 Pro but
    /// jetsam SIGKILLs it as soon as generation starts (prefill + KV cache +
    /// vision tower overflow the per-app budget, even with the
    /// increased-memory-limit entitlement) — verified on device 2026-07-07.
    /// 4B is the real ceiling for phones today.
    private static let model = VLMRegistry.qwen3VL4BInstruct4Bit

    private static var instructions: String {
        """
        You are Good Guy Bad Guy, a wildlife-safety identifier running FULLY \
        ON-DEVICE on the user's iPhone — the open-source model \(model.name) \
        on the phone's GPU via MLX. There is no cloud and no signal needed: \
        photos never leave the phone. The user is typically outdoors (camping, \
        hiking) pointing the camera at something they just found and wants to \
        know if it's dangerous.

        When the user sends a photo of an animal, insect, spider, snake, \
        plant, or mushroom, reply in EXACTLY this format:
        Line 1 is one of: "VERDICT: GOOD GUY" (harmless or beneficial), \
        "VERDICT: BAD GUY" (venomous, toxic, or otherwise dangerous to people \
        or pets), or "VERDICT: CAUTION" (you can't identify it confidently, or \
        it's painful but not dangerous).
        Then a blank line, then a short paragraph: what it is (common name, \
        plus scientific name if you're confident), how confident you are, the \
        visual features that identify it, and one or two sentences of \
        practical advice.

        Safety rules — these override everything else:
        - If it could be a dangerous species OR its harmless look-alike and \
        you can't tell which, say CAUTION and name both candidates. Never \
        guess GOOD GUY between look-alikes.
        - Never tell the user to touch, handle, or move a creature. The advice \
        for a BAD GUY is always to keep distance and leave it alone.
        - Never declare a mushroom, berry, or plant safe to eat. Edibility is \
        out of scope: identification only.
        - If the user may have been bitten or stung, tell them to seek medical \
        help — do not play doctor.

        You may call get_location to learn the region (species vary a lot by \
        region) and get_device_status for the date (season affects what's \
        active). If a tool fails, skip regional context rather than guessing. \
        If the photo isn't a creature or plant, or there's no photo, skip the \
        VERDICT line and answer normally as a helpful assistant. Be concise.
        """
    }

    private var container: ModelContainer?
    private var session: ChatSession?
    /// Conversation so far (user + assistant turns, think-blocks stripped).
    /// Kept here because each turn runs in a FRESH ChatSession — reusing a
    /// session's KV cache across turns is broken for Qwen3-VL in
    /// mlx-swift-lm 3.31.4 (turn 2+ hangs or emits corrupted text, verified
    /// on device 2026-07-07); replaying history costs a short prefill and
    /// stays correct.
    private var history: [Chat.Message] = []

    var modelName: String { Self.model.name }

    func load(onProgress: @escaping @MainActor (Double) -> Void) async throws {
        guard container == nil else { return }

        // Cap MLX's GPU buffer cache so inference stays inside the iOS
        // per-app memory budget.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        DebugLog.log("load() starting, model: \(Self.model.name)")
        let container = try await #huggingFaceLoadModelContainer(
            configuration: Self.model,
            progressHandler: { progress in
                let fraction = progress.fractionCompleted
                DebugLog.log("download progress: \(fraction) (\(progress.completedUnitCount)/\(progress.totalUnitCount))")
                Task { @MainActor in
                    onProgress(fraction)
                }
            }
        )
        DebugLog.log("model container loaded")
        self.container = container
        reset()
    }

    func reset() {
        history = []
        session = nil
    }

    /// One fresh ChatSession per turn (see `history` comment).
    private func makeSession(_ container: ModelContainer) -> ChatSession {
        ChatSession(
            container,
            instructions: Self.instructions,
            // Qwen's recommended sampling for instruct models; the repetition
            // penalty stops the degenerate "2023 and 2024. 2023 and 2024. …"
            // loops a 4-bit 4B model falls into after tool-result injection.
            generateParameters: GenerateParameters(
                temperature: 0.7,
                topP: 0.8,
                repetitionPenalty: 1.15,
                repetitionContextSize: 64
            ),
            tools: PhoneTools.specs + MoreTools.specs,
            toolDispatch: { call in
                DebugLog.log("tool call: \(call.function.name) args: \(call.function.arguments)")
                // A stuck tool must never hang the whole reply (the model
                // waits on this result), so every tool races a 30s deadline.
                let result = await Self.withDeadline(seconds: 30) {
                    if let moreResult = await MoreTools.dispatch(call) { return moreResult }
                    return await PhoneTools.dispatch(call)
                } ?? #"{"error": "tool timed out after 30 seconds"}"#
                DebugLog.log("tool result: \(result.prefix(300))")
                return result
            }
        )
    }

    private static func withDeadline(
        seconds: Double, _ body: @escaping @Sendable () async -> String
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func respond(to prompt: String, image: CIImage?) -> AsyncThrowingStream<String, Error> {
        guard let container else {
            return AsyncThrowingStream { $0.finish(throwing: EngineError.notLoaded) }
        }
        let session = makeSession(container)
        self.session = session

        let userMessage = Chat.Message.user(
            prompt, images: image.map { [.ciImage($0)] } ?? [])
        let turn = history + [userMessage]
        DebugLog.log("turn start (history: \(history.count) msgs)")
        let upstream = session.streamResponse(to: turn)

        // Tap the stream: log raw chunks for debugging, and on completion
        // fold the exchange into `history` for the next turn's replay.
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                var reply = ""
                do {
                    for try await chunk in upstream {
                        DebugLog.log("chunk: \(chunk.debugDescription)")
                        reply += chunk
                        continuation.yield(chunk)
                    }
                    self.commit(user: userMessage, reply: reply)
                    continuation.finish()
                } catch {
                    DebugLog.log("stream error: \(error)")
                    if !reply.isEmpty { self.commit(user: userMessage, reply: reply) }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Append a finished exchange to the replayed history. Think-blocks are
    /// dropped (Qwen convention: prior-turn reasoning is not replayed).
    private func commit(user: Chat.Message, reply: String) {
        var text = reply
        while let start = text.range(of: "<think>") {
            guard let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex)
            else {
                text.removeSubrange(start.lowerBound..<text.endIndex)
                break
            }
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        history.append(user)
        history.append(.assistant(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    enum EngineError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The model is not loaded yet." }
    }
}

#endif
