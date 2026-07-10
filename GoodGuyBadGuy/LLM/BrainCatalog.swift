import Foundation

/// The "brain" — which model identifies the photo.
///
/// Two families:
/// - **Cloud brains** (🛰️, need internet) route to `CloudEngine`, which POSTs
///   the photo to our classifier service. Each carries a `serverModel` telling
///   the server which model to name the organism with ("claude" = the box's
///   free Claude subscription; a BANKR model id = that vision model via the
///   BANKR gateway). The verdict is always the server's curated danger table.
/// - **Local brains** (🏠, work offline) route to the on-device MLX engine.
///   `id` is the Hugging Face repo. **Deliberately curated, not free-text**: an
///   arbitrary repo might not be a vision model, might not be recognized by
///   MLXVLM, or (8B Qwen, verified 2026-07-07) load then get jetsam-killed.
///   4B-4bit is the practical ceiling.
///
/// No MLX import here on purpose, so this also compiles in the simulator (where
/// MockEngine runs). `MLXEngine.configuration(for:)` maps local ids to a real
/// `ModelConfiguration` with the right stop tokens.
struct BrainModel: Identifiable, Equatable, Hashable {
    /// Stable key everything references. A Hugging Face repo (local brains) or
    /// a `cloud-…` sentinel (cloud brains).
    let id: String
    /// Friendly name for the UI.
    let name: String
    /// Approximate download / on-disk size (local), or a hint like "no
    /// download" (cloud).
    let sizeText: String
    /// Relative smarts, 1...6 — rendered as that many 🧠.
    let brains: Int
    /// Shown with a star; also the default on first launch.
    let recommended: Bool
    /// Cloud (needs internet, 🛰️) vs on-device (works offline, 🏠).
    let isCloud: Bool
    /// Cloud brains only: which model the `/classify` server should name with
    /// ("claude" or a BANKR model id). Nil for local brains.
    let serverModel: String?

    /// Brain rating as emoji, e.g. 3 → "🧠🧠🧠".
    var brainRating: String { String(repeating: "🧠", count: max(1, brains)) }
    /// 🛰️ = needs internet, 🏠 = runs on the phone.
    var locationIcon: String { isCloud ? "🛰️" : "🏠" }
}

enum BrainCatalog {
    // MARK: cloud brain sentinels (not Hugging Face repos)
    static let fableID = "cloud-fable"
    static let geminiProID = "cloud-gemini-pro"
    static let geminiFlashID = "cloud-gemini-flash"

    /// Six brains, strongest first: three cloud (🛰️) then three local (🏠).
    static let all: [BrainModel] = [
        BrainModel(
            id: fableID,
            name: "Claude Fable",
            sizeText: "no download",
            brains: 6,
            recommended: true,
            isCloud: true,
            serverModel: "claude"
        ),
        BrainModel(
            id: geminiProID,
            name: "Gemini 3.1 Pro",
            sizeText: "no download",
            brains: 5,
            recommended: false,
            isCloud: true,
            serverModel: "gemini-3.1-pro"
        ),
        BrainModel(
            id: geminiFlashID,
            name: "Gemini 3.1 Flash Lite",
            sizeText: "no download",
            brains: 4,
            recommended: false,
            isCloud: true,
            serverModel: "gemini-3.1-flash-lite"
        ),
        BrainModel(
            id: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit",
            name: "Qwen3-VL 4B",
            sizeText: "~2.7 GB",
            brains: 3,
            recommended: false,
            isCloud: false,
            serverModel: nil
        ),
        BrainModel(
            id: "mlx-community/gemma-3-4b-it-qat-4bit",
            name: "Gemma 3 4B",
            sizeText: "~3.0 GB",
            brains: 2,
            recommended: false,
            isCloud: false,
            serverModel: nil
        ),
        BrainModel(
            id: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
            name: "Qwen2.5-VL 3B",
            sizeText: "~2.0 GB",
            brains: 2,
            recommended: false,
            isCloud: false,
            serverModel: nil
        ),
    ]

    static let defaultID: String = fableID

    static func model(for id: String) -> BrainModel {
        all.first { $0.id == id } ?? all[0]
    }

    static func isCloud(_ id: String) -> Bool { model(for: id).isCloud }

    static func displayName(for id: String) -> String {
        model(for: id).name
    }
}
