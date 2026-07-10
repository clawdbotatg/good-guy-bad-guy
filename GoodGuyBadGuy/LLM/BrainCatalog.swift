import Foundation

/// The "brain" — which on-device model identifies the photo.
///
/// Every brain runs locally via MLX and works with zero signal. `id` is the
/// Hugging Face repo. **Deliberately curated, not free-text**: an arbitrary
/// repo might not be a vision model, might not be recognized by MLXVLM, or
/// (8B Qwen, verified 2026-07-07) load then get jetsam-killed. 4B-4bit is the
/// practical ceiling.
///
/// No MLX import here on purpose, so this also compiles in the simulator
/// (where MockEngine runs). `MLXEngine.configuration(for:)` maps ids to a real
/// `ModelConfiguration` with the right stop tokens.
struct BrainModel: Identifiable, Equatable, Hashable {
    /// Stable key everything references — the Hugging Face repo.
    let id: String
    /// Friendly name for the UI.
    let name: String
    /// Approximate download / on-disk size.
    let sizeText: String
    /// Relative smarts, 1...6 — rendered as that many 🧠.
    let brains: Int
    /// Shown with a star; also the default on first launch.
    let recommended: Bool

    /// Brain rating as emoji, e.g. 3 → "🧠🧠🧠".
    var brainRating: String { String(repeating: "🧠", count: max(1, brains)) }
}

enum BrainCatalog {
    static let qwen3ID = "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit"

    /// Three on-device brains, strongest first.
    static let all: [BrainModel] = [
        BrainModel(
            id: qwen3ID,
            name: "Qwen3-VL 4B",
            sizeText: "~2.7 GB",
            brains: 3,
            recommended: true
        ),
        BrainModel(
            id: "mlx-community/gemma-3-4b-it-qat-4bit",
            name: "Gemma 3 4B",
            sizeText: "~3.0 GB",
            brains: 2,
            recommended: false
        ),
        BrainModel(
            id: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
            name: "Qwen2.5-VL 3B",
            sizeText: "~2.0 GB",
            brains: 2,
            recommended: false
        ),
    ]

    static let defaultID: String = qwen3ID

    static func model(for id: String) -> BrainModel {
        all.first { $0.id == id } ?? all[0]
    }

    static func displayName(for id: String) -> String {
        model(for: id).name
    }
}
