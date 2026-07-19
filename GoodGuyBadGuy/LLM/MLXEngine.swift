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
/// **A photo is answered in two minimal passes, never one big one.**
///
/// 1. *Name it.* Image + a one-line prompt: "in very few words, what is
///    this?" Nothing else — no format, no categories, no safety talk. Asking
///    a 4B model to identify an animal *and* fill in a template in one shot
///    degrades both jobs (device, 2026-07-09). The model often replies with a
///    caption instead of a bare name anyway, so the WHOLE reply is matched
///    against the danger table, and the screen shows either a clean short
///    answer or the curated alias the caption matched (App Review, 2026-07-16:
///    demanding a bare name turned three correct identifications into
///    "couldn't identify").
/// 2. *Judge it.* `DangerTable` looks the reply up. Only if nothing matches
///    does the model get a second, equally tiny question — one word for the
///    category — which selects the safe default.
///
/// The model is the eyes; the table is the encyclopedia. It once called a
/// daylily "safe for cats", which is lethally wrong, so it is never asked.
@MainActor
final class MLXEngine: LLMEngine {
    /// Which brain runs, as a `BrainCatalog` repo id. The UI switches it via
    /// `setModel`; `BrainCatalog` is the curated set of models that actually
    /// fit and load (the 8B Qwen loads on a 12 GB phone but jetsam-kills the
    /// instant it generates — verified 2026-07-07; 4B is the ceiling).
    private var modelID = BrainCatalog.defaultID

    /// Build a real `ModelConfiguration` for a catalog id. The stop tokens
    /// matter: without them a Qwen model never emits EOS and runs to the token
    /// cap every turn, and Gemma likewise. Keyed off the id so any catalog
    /// model works without a per-model table here.
    private static func configuration(for id: String) -> ModelConfiguration {
        let eos: Set<String>
        if id.contains("Qwen") {
            eos = ["<|im_end|>"]
        } else if id.lowercased().contains("gemma") {
            eos = ["<end_of_turn>"]
        } else {
            eos = []
        }
        return ModelConfiguration(id: id, extraEOSTokens: eos)
    }

    /// Pass 1. As little context as possible: look, and name it.
    ///
    /// The example names are deliberately species that do NOT appear in
    /// `DangerData` — the whole reply is danger-table matching input now, so
    /// an echoed example must never be able to fire a table entry.
    private static let nameInstructions = """
        Look at the photo and name the animal, plant, or mushroom in it.

        Answer with the name only — no sentence, no punctuation, no \
        explanation. Two to six words. Like: House sparrow. Or: Goldfish. \
        Or: Maple tree.

        If it is not a living thing, answer: not a plant or animal
        If you truly cannot tell, answer: unknown
        Never say whether it is dangerous or safe.
        """

    /// Pass 2, and only when the name isn't already in the danger table: one
    /// word, to pick the safe default.
    private static let categoryInstructions = """
        Answer with exactly one word from this list and nothing else:
        snake, spider, scorpion, insect, plant, mushroom, mammal, bird, other
        """

    /// Follow-up questions after a verdict has been rendered.
    private var followupInstructions: String {
        """
        You are Good Guy Bad Guy, a wildlife-safety helper running fully \
        on-device on the user's iPhone (\(modelName) via MLX — no cloud, \
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
    }

    /// Fast, accurate first look for the plants people get hurt by. Runs
    /// before the VLM and, when confident, decides the verdict on its own via
    /// `DangerTable`; a low-confidence or non-plant photo falls through to the
    /// VLM (see `identify`). Nil if the bundled model is missing — then every
    /// photo just uses the VLM, as before.
    private let plantClassifier = PlantClassifier()

    private var container: ModelContainer?
    /// Conversation so far (user + assistant turns, think-blocks stripped).
    /// Kept here because each turn runs in a FRESH ChatSession — reusing a
    /// session's KV cache across turns is broken for Qwen3-VL in
    /// mlx-swift-lm 3.31.4 (turn 2+ hangs or emits corrupted text, verified
    /// on device 2026-07-07); replaying history costs a short prefill and
    /// stays correct.
    private var history: [Chat.Message] = []

    var modelName: String { BrainCatalog.displayName(for: modelID) }

    func setModel(_ id: String) {
        guard id != modelID else { return }
        DebugLog.log("setModel: \(modelID) -> \(id)")
        modelID = id
        // Drop the loaded brain so the next load() downloads/loads the new
        // one; ARC frees the old ModelContainer's weights.
        container = nil
        history = []
    }

    func load(onProgress: @escaping @MainActor (Double) -> Void) async throws {
        guard container == nil else { return }

        // Cap MLX's GPU buffer cache so inference stays inside the iOS
        // per-app memory budget.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        let configuration = Self.configuration(for: modelID)
        DebugLog.log("load() starting, model: \(modelID)")
        let container = try await #huggingFaceLoadModelContainer(
            configuration: configuration,
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

    /// One fresh ChatSession per turn (see `history` comment). The two
    /// identification passes get no tools: they should look at the photo and
    /// answer, not reach for the phone.
    private func makeSession(
        _ container: ModelContainer, instructions: String, maxTokens: Int,
        temperature: Float = 0.7, withTools: Bool = false
    ) -> ChatSession {
        ChatSession(
            container,
            instructions: instructions,
            // Qwen's recommended sampling for instruct models (identification
            // passes run cooler — see `identify`); the repetition penalty
            // stops the degenerate "2023 and 2024. 2023 and 2024. …"
            // loops a 4-bit 4B model falls into. Keep the window at 64: at 128
            // a keyword the answer needs is still in-window when it starts,
            // the penalty vetoes completing the word, and the model stutters
            // (seen on device 2026-07-09). maxTokens is the hard stop when EOS
            // never fires.
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                temperature: temperature,
                topP: 0.8,
                repetitionPenalty: 1.15,
                repetitionContextSize: 64
            ),
            tools: withTools ? PhoneTools.specs + MoreTools.specs : [],
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

    // MARK: photo → name, then name → verdict

    private func identify(_ image: CIImage, container: ModelContainer) -> AsyncThrowingStream<
        String, Error
    > {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    // ---- Fast path: the on-device plant classifier ----
                    // For poison ivy / oak / sumac and their common harmless
                    // look-alikes, a purpose-trained Core ML model is more
                    // accurate than the 4B VLM. When it's confident enough
                    // (PlantRoute), it names the plant and the table decides;
                    // otherwise we fall through to the VLM for snakes, spiders,
                    // other creatures, and uncertain plants.
                    if let classifier = self.plantClassifier,
                        let p = classifier.classify(image)
                    {
                        let route = PlantRoute.decide(p)
                        DebugLog.log(
                            "plant classifier: \(p.commonName) conf=\(p.confidence) bad=\(p.isDangerous) use=\(route.use) hedged=\(route.hedged)"
                        )
                        if route.use {
                            let display =
                                p.commonName.prefix(1).uppercased() + p.commonName.dropFirst()
                            continuation.yield("ID: \(display)\n")
                            let result = DangerTable.verdict(
                                name: p.commonName, category: "plant", hedged: route.hedged)
                            continuation.yield(result.text)
                            self.history = [
                                .user("[photo of a plant the user found]"),
                                .assistant("ID: \(display)\n\(result.text)"),
                            ]
                            continuation.finish()
                            return
                        }
                    }

                    // ---- Pass 1: what is it? ----
                    // maxTokens must leave room for the model to FINISH: it
                    // often ignores "name only" and captions ("This is a
                    // close-up photograph of a **spitting cobra**…"). At 32
                    // that caption was cut mid-sentence and the name pass
                    // looked like a failure — the App Review rejection
                    // (2026-07-16). Cooler temperature for the same reason:
                    // identification is a lookup, not a chat.
                    let raw = try await self.ask(
                        instructions: Self.nameInstructions, prompt: "What is this?",
                        image: image, maxTokens: 96, temperature: 0.2, container: container)
                    let reply = Self.stripThinking(raw)
                    DebugLog.log("name pass: \(reply.debugDescription)")

                    if DangerTable.isNotAnOrganism(reply) {
                        continuation.yield(
                            "That doesn't look like a plant or animal. Point the camera at the creature, plant, or mushroom you want checked."
                        )
                        self.history = []
                        continuation.finish()
                        return
                    }

                    // Everything the model wrote is matching input — even an
                    // unclosed think-block names the animal it is reasoning
                    // about. Only the tags themselves are removed.
                    let matchText = DangerTable.matchText(
                        raw.replacingOccurrences(of: "<think>", with: " ")
                            .replacingOccurrences(of: "</think>", with: " "))
                    // Shown to the user: a clean short answer if we got one,
                    // else the curated alias the caption matched.
                    let name =
                        DangerTable.sanitizeName(reply)
                        ?? DangerTable.matchedName(in: matchText ?? "")
                    let hedged = DangerTable.isHedged(reply)

                    // Show the identification immediately — the user asked
                    // what it is, and the danger pass may take a moment.
                    continuation.yield("ID: \(name ?? "Couldn't identify it")\n")

                    // ---- Pass 2: how dangerous is it? ----
                    // The table answers directly for anything it knows. Only
                    // an unmatched reply needs the model's category, and only
                    // to pick the safe default.
                    var category: String?
                    if let matchText, DangerTable.lookup(name: matchText) == nil {
                        category = try await self.categorize(
                            name, image: image, container: container)
                        DebugLog.log("category pass: \(category ?? "nil")")
                    }

                    let result = DangerTable.verdict(
                        name: matchText, category: category, hedged: hedged)
                    DebugLog.log(
                        "id=\(name ?? "none") verdict=\(result.verdict.map(String.init(describing:)) ?? "none")")
                    continuation.yield(result.text)

                    // History carries the verdict the user saw, so follow-ups
                    // reason from those facts.
                    self.history = [
                        .user("[photo of something the user found]"),
                        .assistant("ID: \(name ?? "unidentified")\n\(result.text)"),
                    ]
                    continuation.finish()
                } catch {
                    DebugLog.log("identify error: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// One-word category, used only to pick the safe default for a reply the
    /// danger table doesn't know.
    private func categorize(_ name: String?, image: CIImage, container: ModelContainer)
        async throws -> String?
    {
        let prompt =
            if let name { "This looks like: \(name). Which one word describes it?" } else {
                "Which one word describes what is in the photo?"
            }
        let reply = try await ask(
            instructions: Self.categoryInstructions, prompt: prompt,
            image: image, maxTokens: 8, temperature: 0.2, container: container)
        let word = DangerTable.firstMeaningfulLine(Self.stripThinking(reply))?
            .lowercased()
            .trimmingCharacters(in: CharacterSet.letters.inverted)
        return word.flatMap { DangerTable.categories.contains($0) ? $0 : nil }
    }

    /// Run one short, tool-free, history-free question against the photo.
    /// Returns the raw reply — think-blocks and all; the caller decides what
    /// to strip and what to mine.
    private func ask(
        instructions: String, prompt: String, image: CIImage, maxTokens: Int,
        temperature: Float, container: ModelContainer
    ) async throws -> String {
        let session = makeSession(
            container, instructions: instructions, maxTokens: maxTokens,
            temperature: temperature)
        let message = Chat.Message.user(prompt, images: [.ciImage(image)])
        var raw = ""
        for try await chunk in session.streamResponse(to: [message]) { raw += chunk }
        return raw
    }

    // MARK: text follow-ups

    private func followUp(_ prompt: String, container: ModelContainer) -> AsyncThrowingStream<
        String, Error
    > {
        let session = makeSession(
            container, instructions: followupInstructions, maxTokens: 300, withTools: true)
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
