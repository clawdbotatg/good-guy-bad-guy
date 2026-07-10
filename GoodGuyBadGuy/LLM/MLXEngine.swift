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
///
/// **Two-stage design.** A photo turn does NOT ask the model whether
/// something is dangerous — it asks only "what is this?", then
/// `DangerTable` decides the verdict from curated data. The model is the
/// eyes; the table is the encyclopedia. (It once called a daylily "safe for
/// cats", which is lethally wrong; see `DangerTable`.) Text turns after a
/// verdict are ordinary conversation.
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

    /// Stage 1. Identification only — no safety claims, no verdict. Keeping
    /// the model off the safety question is the whole point of the design.
    ///
    /// Written as a worked EXAMPLE rather than an angle-bracket template: a
    /// 4B model parrots `<common name>` straight back, and that placeholder
    /// then reaches the user as an identification (device, 2026-07-09).
    private static let identifyInstructions = """
        You identify organisms in photos for a wildlife-safety app. You are \
        shown ONE photo. Name the single most likely organism in it.

        Answer with exactly three lines, shaped like this example:

        CATEGORY: spider
        ID: Cellar spider (Pholcus phalangioides)
        FEATURES: very long thin legs and a small pale body on a textured wall

        Rules:
        - CATEGORY must be exactly one of these words: snake, spider, \
        scorpion, insect, plant, mushroom, mammal, bird, other.
        - ID must be a real name you believe fits THIS photo. Never copy the \
        example, and never write placeholders, brackets, or the words \
        "common name".
        - FEATURES: one short sentence on what you actually see in this photo.
        - If you are not confident, still give your best guess and add \
        " (uncertain)" after the name.
        - If the photo has no living thing in it, answer CATEGORY: other and \
        ID: not a plant or animal
        - Never say whether it is dangerous, venomous, poisonous, or safe. \
        Another system decides that. Output the three lines only.
        """

    /// Fallback when the structured reply gives no usable name. The app must
    /// always tell the user what it thinks the thing is, so we drop the
    /// format entirely and just ask.
    private static let nameOnlyInstructions = """
        Look at the photo and name the animal, plant, or mushroom in it.

        Reply with ONLY the name — two to six words, no sentence, no \
        punctuation, no explanation. For example: Cellar spider, or Eastern \
        gray squirrel, or Fly agaric mushroom.

        If you truly cannot tell what it is, reply with exactly: unknown
        Never say whether it is dangerous or safe.
        """

    /// Stage 2 is the app. This is only for follow-up questions after a
    /// verdict has already been rendered.
    private static let followupInstructions = """
        You are Good Guy Bad Guy, a wildlife-safety helper running fully \
        on-device on the user's iPhone (\(model.name) via MLX — no cloud, \
        photos never leave the phone). The user photographed something and \
        already received a verdict, shown earlier in this conversation.

        Answer their follow-up briefly — a few sentences, no filler. The \
        verdict and safety facts already given are authoritative: do not \
        contradict them, and do not invent new toxicity or venom claims. If \
        you don't know, say so and tell them to check with a local expert, \
        poison control, or a vet.

        Never advise touching, handling, moving, or eating anything. If they \
        may have been bitten or stung, tell them to seek medical help. If a \
        pet may have eaten something toxic, tell them to call a vet now.
        """

    private var container: ModelContainer?
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
    }

    /// One fresh ChatSession per turn (see `history` comment).
    private func makeSession(
        _ container: ModelContainer, instructions: String, maxTokens: Int
    ) -> ChatSession {
        ChatSession(
            container,
            instructions: instructions,
            // Qwen's recommended sampling for instruct models; the repetition
            // penalty stops the degenerate "2023 and 2024. 2023 and 2024. …"
            // loops a 4-bit 4B model falls into. Keep the window at 64: at 128
            // a keyword the format requires (e.g. "VERDICT") is still
            // in-window when the answer starts, the penalty vetoes completing
            // the word, and the model stutters "VERD\nVERD\nVERD" (seen on
            // device 2026-07-09). maxTokens is the hard stop when EOS never
            // fires.
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
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
        if let image {
            return identify(image, container: container)
        }
        return followUp(prompt, container: container)
    }

    // MARK: stage 1 — identify, then let the table decide

    /// Collects the model's identification in full (nothing is streamed to the
    /// UI: the raw `CATEGORY:/ID:/FEATURES:` lines are machinery, not an
    /// answer), runs the danger lookup, and emits the composed verdict.
    private func identify(_ image: CIImage, container: ModelContainer) -> AsyncThrowingStream<
        String, Error
    > {
        // A fresh photo is identified on its own — prior turns about a
        // different creature would only bias the ID.
        let session = makeSession(
            container, instructions: Self.identifyInstructions, maxTokens: 160)
        let userMessage = Chat.Message.user(
            "Identify the organism in this photo.", images: [.ciImage(image)])
        let upstream = session.streamResponse(to: [userMessage])

        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    var raw = ""
                    for try await chunk in upstream { raw += chunk }
                    DebugLog.log("identify raw: \(Self.stripThinking(raw))")

                    var identification = DangerTable.identify(
                        modelText: Self.stripThinking(raw))

                    // The structured format failed us — ask the plain question
                    // rather than showing a verdict with no identification.
                    if identification.name == nil, !identification.notAnOrganism {
                        DebugLog.log("no name parsed — second pass, name only")
                        if let name = try await self.nameOnly(image, container: container) {
                            DebugLog.log("second pass name: \(name)")
                            identification = DangerTable.Identification(
                                category: identification.category,
                                name: name,
                                features: identification.features,
                                notAnOrganism: false,
                                uncertain: false
                            )
                        }
                    }

                    let result = DangerTable.verdict(identification)
                    DebugLog.log(
                        "id: \(identification.name ?? "none") verdict: \(result.verdict.map(String.init(describing:)) ?? "none")")

                    continuation.yield(result.text)
                    // History carries the composed verdict (not the raw ID
                    // lines) so follow-ups reason from the facts the user saw.
                    self.history = [
                        .user("[photo of something the user found]"),
                        .assistant(result.text),
                    ]
                    continuation.finish()
                } catch {
                    DebugLog.log("identify error: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Second pass: no format, just "what is it?". Returns nil when the model
    /// says `unknown` or hands back something unusable.
    private func nameOnly(_ image: CIImage, container: ModelContainer) async throws -> String? {
        let session = makeSession(
            container, instructions: Self.nameOnlyInstructions, maxTokens: 40)
        let message = Chat.Message.user(
            "What is this? Name it.", images: [.ciImage(image)])
        var raw = ""
        for try await chunk in session.streamResponse(to: [message]) { raw += chunk }

        // Take the first real line and strip the decoration a small model adds.
        let line = DangerTable.firstMeaningfulLine(Self.stripThinking(raw))
        guard let line, line.count <= 60,
            line.range(of: "unknown", options: .caseInsensitive) == nil,
            !line.contains("<")
        else { return nil }
        return line
    }

    // MARK: text follow-ups

    private func followUp(_ prompt: String, container: ModelContainer) -> AsyncThrowingStream<
        String, Error
    > {
        let session = makeSession(
            container, instructions: Self.followupInstructions, maxTokens: 300)
        let userMessage = Chat.Message.user(prompt)
        let upstream = session.streamResponse(to: history + [userMessage])
        DebugLog.log("follow-up (history: \(history.count) msgs)")

        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                var reply = ""
                do {
                    for try await chunk in upstream {
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
        history.append(user)
        history.append(
            .assistant(
                Self.stripThinking(reply).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Qwen 3.x emits `<think>…</think>`; strip it before parsing or replaying.
    private static func stripThinking(_ text: String) -> String {
        var s = text
        while let start = s.range(of: "<think>") {
            guard let end = s.range(of: "</think>", range: start.upperBound..<s.endIndex) else {
                s.removeSubrange(start.lowerBound..<s.endIndex)
                break
            }
            s.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum EngineError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "The model is not loaded yet." }
    }
}

#endif
