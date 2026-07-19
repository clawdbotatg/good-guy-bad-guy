import CoreImage
import Foundation
import UIKit

/// Owns the message list the UI renders and runs the bundled classifier.
///
/// The old download/brain-selection lifecycle is gone: the model ships inside
/// the app (`PoisonIvyClassifier.mlmodelc`, ~70 KB) and is ready the instant
/// the app opens. A photo is the whole question — there is no text chat.
@Observable
@MainActor
final class ChatStore {
    private(set) var messages: [ChatMessage] = []
    private(set) var isGenerating = false

    private let engine = ClassifierEngine()
    private var task: Task<Void, Never>?

    /// Identify a photo. Text is ignored — this app answers pictures only.
    func send(_ text: String = "", image: UIImage? = nil) {
        guard !isGenerating, let image else { return }

        messages.append(ChatMessage(role: .user, text: "Good guy or bad guy?", image: image))
        messages.append(ChatMessage(role: .assistant, text: ""))
        let index = messages.count - 1
        isGenerating = true
        let ciImage = Self.modelImage(from: image)
        DebugLog.log("send: +image")

        task = Task {
            guard let ciImage else {
                messages[index].text =
                    "ID: Couldn't read the photo\n"
                    + DangerTable.verdict(name: nil, category: "plant").text
                isGenerating = false
                return
            }
            let answer = engine.identify(ciImage)
            // Reveal the identification first, then the verdict a beat later —
            // the classification itself is near-instant, but the two-step
            // reveal reads as "looking… deciding…" instead of a blank flash.
            messages[index].text = answer.idLine
            try? await Task.sleep(for: .milliseconds(450))
            if Task.isCancelled { isGenerating = false; return }
            messages[index].text = answer.text
            DebugLog.log("verdict: \(answer.idLine)")
            isGenerating = false
        }
    }

    func stopGenerating() { task?.cancel() }

    /// New scan: clear the conversation.
    func clear() {
        stopGenerating()
        messages.removeAll()
    }

    /// Prepare a photo for the classifier: draw it upright and capped in size.
    ///
    /// `CIImage(image:)` ignores `UIImage.imageOrientation`, so portrait camera
    /// shots would reach the model rotated 90°; drawing through
    /// `UIGraphicsImageRenderer` bakes the orientation in and resamples to a
    /// sane size. (Kept from the VLM era — the same orientation bug bit the
    /// classifier's Vision request.)
    private static let maxImageSide: CGFloat = 1280

    private static func modelImage(from image: UIImage) -> CIImage? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxImageSide / max(longest, 1))
        let target = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return CIImage(image: drawn)
    }
}
