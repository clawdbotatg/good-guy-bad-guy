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
                if message.role == .assistant, message.identification != nil {
                    identificationBlock
                }
                if message.role == .assistant, message.identification != nil,
                    message.verdict == nil
                {
                    // Named it; now looking the name up in the danger table.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking if it's dangerous…").foregroundStyle(.secondary)
                    }
                } else if message.isThinking && message.bodyText.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking…").foregroundStyle(.secondary)
                    }
                } else if message.bodyText.isEmpty && message.image == nil
                    && message.verdict == nil && message.identification == nil
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

    /// What the model thinks it is, and why. Shown above the note so a
    /// misidentification is obvious at a glance: the verdict is only as good
    /// as the ID it was looked up from, and the user is the one who can see
    /// both the animal and the name.
    @ViewBuilder
    private var identificationBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let identification = message.identification {
                Text(identification)
                    .font(.headline)
                    .textSelection(.enabled)
            }
            if let observed = message.observed {
                Text("Model saw: \(observed)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
    }

    /// Shown under every verdict. Photo ID can be wrong — look-alikes are the
    /// whole hazard — so the app never implies permission to touch or eat.
    private var disclaimer: some View {
        Text(
            "AI identification from one photo. It can be wrong — check the ID above, and never touch, handle, or eat anything based on this. In an emergency call poison control or a vet."
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
