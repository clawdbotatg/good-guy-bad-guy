import SwiftUI

/// The persistent "Brain" section under the title: which on-device model is
/// running, its download status, and a tap-to-expand list to switch or
/// download another. Stays put while the content below swaps between the
/// photo prompt and the chat.
struct BrainView: View {
    let store: ChatStore
    // Launch with GGBG_BRAIN_OPEN=1 to start expanded (automated screenshots).
    @State private var expanded =
        ProcessInfo.processInfo.environment["GGBG_BRAIN_OPEN"] != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider().padding(.leading, 44)
                ForEach(store.availableModels) { model in
                    modelRow(model)
                    if model.id != store.availableModels.last?.id {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    // MARK: collapsed header

    private var header: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Brain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(store.currentModel.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Spacer()
                status
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var status: some View {
        switch store.modelState {
        case .downloading(let fraction):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(fraction > 0 ? "\(Int(fraction * 100))%" : "…")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    // MARK: expanded model list

    @ViewBuilder
    private func modelRow(_ model: BrainModel) -> some View {
        let isCurrent = model.id == store.currentModelID
        Button {
            store.selectModel(model.id)
            if !isCurrent { withAnimation(.snappy) { expanded = false } }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isCurrent ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 32)
                HStack(spacing: 6) {
                    Text(model.name).font(.subheadline.weight(.semibold))
                    if model.recommended {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Text(model.brainRating).font(.caption)
                }
                .lineLimit(1)
                Spacer()
                trailing(for: model, isCurrent: isCurrent)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isDownloading && !isCurrent)
    }

    @ViewBuilder
    private func trailing(for model: BrainModel, isCurrent: Bool) -> some View {
        if isCurrent, case .downloading(let fraction) = store.modelState {
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: max(fraction, 0.02))
                    .frame(width: 56)
                Text(fraction > 0 ? "\(Int(fraction * 100))%" : "starting")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else if isCurrent {
            Text("In use")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                let actionStyle: AnyShapeStyle =
                    store.isDownloading ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)
                if store.isDownloaded(model.id) {
                    Text("Use")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(actionStyle)
                } else {
                    Label("Download", systemImage: "arrow.down.circle")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(actionStyle)
                }
                Text(model.sizeText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
