import PhotosUI
import SwiftUI

struct ChatView: View {
    let store: ChatStore
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            // Demo hook for automated simulator screenshots: launch with
            // SIMCTL_CHILD_GGBG_DEMO=1 to auto-send a photo so the verdict
            // renders without driving taps.
            if ProcessInfo.processInfo.environment["GGBG_DEMO"] != nil,
                store.messages.isEmpty
            {
                let image =
                    UIImage(named: "DemoPhoto")
                    ?? UIGraphicsImageRenderer(size: .init(width: 240, height: 240))
                    .image { ctx in
                        UIColor.systemGreen.setFill()
                        ctx.fill(.init(x: 0, y: 0, width: 240, height: 240))
                    }
                store.send("", image: image)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            // A captured photo IS the question — send it immediately.
            CameraPicker { store.send("", image: $0) }
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) {
            guard let photoItem else { return }
            Task {
                if let data = try? await photoItem.loadTransferable(type: Data.self),
                    let image = UIImage(data: data)
                {
                    store.send("", image: image)
                }
                self.photoItem = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Good Guy Bad Guy")
                    .font(.title.bold())
                Text("On-device · works offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !store.messages.isEmpty {
                Button {
                    store.clear()
                } label: {
                    Label("New scan", systemImage: "arrow.counterclockwise")
                        .font(.subheadline)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if store.messages.isEmpty {
                        emptyState
                    }
                    ForEach(store.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    // A photo taken after the first verdict starts another scan.
                    if !store.messages.isEmpty {
                        scanAgainButton
                    }
                }
                .padding()
            }
            .onChange(of: store.messages.last?.text) {
                if let last = store.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("🌿")
                .font(.system(size: 44))
            Text("Poison ivy, or a harmless look-alike?")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(
                "Not sure if that plant is poison ivy, oak, or sumac? Snap a photo — it names the plant and tells you if it's a rash-causer or a harmless look-alike. No typing, works offline."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Button {
                showCamera = true
            } label: {
                Label("Take a Photo", systemImage: "camera.fill")
                    .font(.headline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            Button("Photo Library") { showPhotoPicker = true }
                .font(.subheadline)
        }
        .padding(.top, 40)
        .padding(.horizontal, 24)
    }

    private var scanAgainButton: some View {
        HStack(spacing: 12) {
            Button {
                showCamera = true
            } label: {
                Label("Scan another", systemImage: "camera.fill")
            }
            .buttonStyle(.borderedProminent)
            Button("Photo Library") { showPhotoPicker = true }
        }
        .font(.subheadline)
        .padding(.top, 4)
        .disabled(store.isGenerating)
    }
}
