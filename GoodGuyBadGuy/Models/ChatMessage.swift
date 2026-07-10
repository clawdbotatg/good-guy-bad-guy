import Foundation
import UIKit

struct ChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
    }

    /// The model opens every identification with a "VERDICT: …" line
    /// (see MLXEngine.instructions); the UI renders it as a colored banner.
    enum Verdict {
        case goodGuy
        case badGuy
        case caution
    }

    let id = UUID()
    let role: Role
    var text: String
    /// Photo the user attached (camera or library), shown in the bubble and
    /// sent to the vision model.
    var image: UIImage?

    init(role: Role, text: String, image: UIImage? = nil) {
        self.role = role
        self.text = text
        self.image = image
    }

    /// Qwen 3.x models can emit `<think>…</think>` reasoning blocks before the
    /// answer. Strip them for display; an unclosed tag means it is still thinking.
    var displayText: String {
        var s = text
        while let start = s.range(of: "<think>") {
            if let end = s.range(of: "</think>", range: start.upperBound..<s.endIndex) {
                s.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                s.removeSubrange(start.lowerBound..<s.endIndex)
                break
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isThinking: Bool {
        text.contains("<think>") && !text.contains("</think>")
    }

    /// Parsed verdict, `nil` until the streamed first line is classifiable.
    /// BAD is checked first so a muddled line errs toward the red banner.
    var verdict: Verdict? {
        guard let line = verdictLine else { return nil }
        if line.contains("BAD") { return .badGuy }
        if line.contains("CAUTION") { return .caution }
        if line.contains("GOOD") { return .goodGuy }
        return nil
    }

    /// `displayText` minus the verdict line — what the bubble body renders.
    /// Empty while the verdict line itself is still streaming in.
    var bodyText: String {
        let s = displayText
        guard verdictLine != nil else { return s }
        guard let newline = s.firstIndex(of: "\n") else { return "" }
        return String(s[s.index(after: newline)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First line when the reply is (or is streaming toward) "VERDICT: …".
    private var verdictLine: String? {
        let first = displayText.prefix(while: { $0 != "\n" })
        guard first.hasPrefix("VERDICT") || (!first.isEmpty && "VERDICT:".hasPrefix(first))
        else { return nil }
        return String(first)
    }
}
