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
        You are Good Guy Bad Guy, a wildlife-safety classifier running FULLY \
        ON-DEVICE on the user's iPhone (\(model.name) via MLX — no cloud, \
        photos never leave the phone). The user photographs something they \
        found outdoors. The photo arrives with no real text: the picture IS \
        the question — what is this, and is it harmful?

        Reply in EXACTLY this format:
        Line 1 is one of: "VERDICT: GOOD GUY" (harmless or beneficial), \
        "VERDICT: BAD GUY" (venomous, toxic, or dangerous to people or pets), \
        or "VERDICT: CAUTION" (can't identify it confidently, or painful but \
        not dangerous).
        Then a blank line, then AT MOST 3 short sentences: what it is (common \
        name, plus scientific name only if confident), why the verdict, and \
        what to do. No greetings, no filler, no restating the question.

        Safety rules — these override everything else:
        - Dangerous species vs. harmless look-alike and you can't tell which \
        → CAUTION, name both. Never guess GOOD GUY between look-alikes.
        - Never advise touching, handling, moving, or eating anything.
        - If the user may have been bitten or stung, tell them to seek \
        medical help.

        You may call get_location (species vary by region) or \
        get_device_status (date/season) — only when it would change the \
        answer. If the photo shows no creature, plant, or mushroom, say what \
        you see in one sentence with no VERDICT line. Text follow-ups get \
        brief, direct answers.
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
            // Keep the window at 64: at 128 the format's own "VERDICT" (from
            // the think block / earlier context) is still in-window when the
            // answer starts, the penalty vetoes completing the word, and the
            // model stutters "VERD\nVERD\nVERD" (seen on device 2026-07-09).
            // Whole-answer restart loops are longer than this window by
            // design — loopCutIndex cuts those deterministically, and
            // maxTokens is the hard stop when EOS never fires.
            generateParameters: GenerateParameters(
                maxTokens: 250,
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
                        let candidate = reply + chunk
                        if let cut = Self.loopCutIndex(candidate) {
                            let kept = String(candidate[..<cut])
                            if kept.count > reply.count {
                                continuation.yield(String(kept.dropFirst(reply.count)))
                            }
                            reply = kept.trimmingCharacters(in: .whitespacesAndNewlines)
                            DebugLog.log("repetition loop detected — cut reply at \(reply.count) chars")
                            break
                        }
                        reply = candidate
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

    /// Qwen3-VL-4B-4bit sometimes fails to emit EOS after a complete verdict
    /// and restarts the whole answer ("…move it.\n\nVERD\n\nVERDICT: …") —
    /// the loop is a whole answer long, so the repetition penalty alone can't
    /// reliably kill it. Any "VERD" appearing after the first VERDICT means
    /// the format is restarting; cut generation right before it.
    private static func loopCutIndex(_ text: String) -> String.Index? {
        guard let first = text.range(of: "VERDICT") else { return nil }
        return text.range(of: "VERD", range: first.upperBound..<text.endIndex)?.lowerBound
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
