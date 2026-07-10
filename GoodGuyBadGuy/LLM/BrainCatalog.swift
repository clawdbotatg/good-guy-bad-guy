import Foundation

/// The "brain" — which open-source vision model runs on the phone.
///
/// Every entry here is a model the shared MLX loader can actually route and
/// that fits a phone's memory budget. **Deliberately curated, not a free-text
/// field**: an arbitrary repo id might not be a vision model, might not be
/// recognized by MLXVLM, or (the 8B Qwen, verified 2026-07-07) might load and
/// then get jetsam-killed the instant it generates. 4B-4bit is the practical
/// ceiling.
///
/// This file has no MLX import on purpose, so it also compiles in the
/// simulator (where MockEngine runs). `MLXEngine.configuration(for:)` maps
/// these ids to a real `ModelConfiguration` with the right stop tokens.
struct BrainModel: Identifiable, Equatable, Hashable {
    /// Hugging Face repo id — the stable key everything else references.
    let id: String
    /// Friendly name for the UI.
    let name: String
    /// Approximate download / on-disk size.
    let sizeText: String
    /// Relative smarts, 1...4 — rendered as that many 🧠.
    let brains: Int
    /// Shown with a star; also the default on first launch.
    let recommended: Bool

    /// Brain rating as emoji, e.g. 3 → "🧠🧠🧠".
    var brainRating: String { String(repeating: "🧠", count: max(1, brains)) }
}

enum BrainCatalog {
    /// Ordered biggest-brain-first (roughly best → smallest). The recommended
    /// one is the default and sits at the top.
    static let all: [BrainModel] = [
        BrainModel(
            id: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit",
            name: "Qwen3-VL 4B",
            sizeText: "~2.7 GB",
            brains: 4,
            recommended: true
        ),
        BrainModel(
            id: "mlx-community/gemma-3-4b-it-qat-4bit",
            name: "Gemma 3 4B",
            sizeText: "~3.0 GB",
            brains: 3,
            recommended: false
        ),
        BrainModel(
            id: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
            name: "Qwen2.5-VL 3B",
            sizeText: "~2.0 GB",
            brains: 3,
            recommended: false
        ),
        BrainModel(
            id: "mlx-community/Qwen2-VL-2B-Instruct-4bit",
            name: "Qwen2-VL 2B",
            sizeText: "~1.4 GB",
            brains: 2,
            recommended: false
        ),
        BrainModel(
            id: "mlx-community/SmolVLM-Instruct-4bit",
            name: "SmolVLM",
            sizeText: "~1.0 GB",
            brains: 1,
            recommended: false
        ),
    ]

    static let defaultID: String =
        all.first(where: \.recommended)?.id ?? all[0].id

    static func model(for id: String) -> BrainModel {
        all.first { $0.id == id } ?? all[0]
    }

    static func displayName(for id: String) -> String {
        model(for: id).name
    }
}
