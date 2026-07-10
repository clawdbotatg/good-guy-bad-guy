import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }

            VStack(alignment: .leading, spacing: 8) {
                if let image = message.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if message.role == .assistant, let verdict = message.verdict {
                    verdictBanner(verdict)
                }
                if message.isThinking && message.bodyText.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").foregroundStyle(.secondary)
                    }
                } else if message.bodyText.isEmpty && message.image == nil
                    && message.verdict == nil
                {
                    ProgressView().controlSize(.small)
                } else if !message.bodyText.isEmpty {
                    Text(message.bodyText)
                        .textSelection(.enabled)
                }
                if message.role == .assistant, message.verdict != nil,
                    !message.bodyText.isEmpty
                {
                    disclaimer
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.role == .user
                    ? AnyShapeStyle(.tint)
                    : AnyShapeStyle(.fill.secondary),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .foregroundStyle(message.role == .user ? .white : .primary)

            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }

    /// Shown under every verdict. Photo ID can be wrong — look-alikes are the
    /// whole hazard — so the app never implies permission to touch or eat.
    private var disclaimer: some View {
        Text(
            "AI identification from one photo. It can be wrong — never touch, handle, or eat anything based on this. In an emergency call poison control or a vet."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func verdictBanner(_ verdict: ChatMessage.Verdict) -> some View {
        let (label, icon, color): (String, String, Color) =
            switch verdict {
            case .goodGuy: ("GOOD GUY", "checkmark.shield.fill", .green)
            case .badGuy: ("BAD GUY", "exclamationmark.triangle.fill", .red)
            case .caution: ("CAUTION", "questionmark.diamond.fill", .orange)
            }
        return HStack(spacing: 8) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.headline.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color, in: Capsule())
    }
}
