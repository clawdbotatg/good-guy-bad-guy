import PhotosUI
import SwiftUI

struct ChatView: View {
    let store: ChatStore
    @State private var draft = ""
    @State private var speech = SpeechRecognizer()
    @State private var draftBeforeDictation = ""
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @FocusState private var inputFocused: Bool

    var body: some View {
        // Title and Brain stay put; only `content` swaps between the photo
        // prompt and the chat.
        VStack(spacing: 0) {
            header
            BrainView(store: store)
                .padding(.top, 2)
                .padding(.bottom, 8)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            store.activate()
            // Demo hook for automated simulator screenshots: launch with
            // SIMCTL_CHILD_GGBG_DEMO=1 to auto-send a photo so the verdict
            // renders without driving taps.
            if ProcessInfo.processInfo.environment["GGBG_DEMO"] != nil,
                store.messages.isEmpty
            {
                let image = UIGraphicsImageRenderer(size: .init(width: 240, height: 240))
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

    @ViewBuilder
    private var content: some View {
        switch store.modelState {
        case .ready:
            VStack(spacing: 0) {
                messageList
                // Image-first: no composer until the first verdict is in; then
                // it appears for follow-up questions.
                if !store.messages.isEmpty { composer }
            }
        case .idle, .downloading:
            preparingScreen
        case .failed(let message):
            failureScreen(message)
        }
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
                }
                .padding()
            }
            .onChange(of: store.messages.last?.text) {
                if let last = store.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onTapGesture { inputFocused = false }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("🐍🕷️🍄")
                .font(.system(size: 44))
            Text("Good guy or bad guy?")
                .font(.title2.bold())
            Text(
                "Found a snake, spider, bug, plant, or mushroom? Snap a photo — no typing needed. It names what it is, then tells you if it's dangerous."
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

    private var composer: some View {
        composerRow
            .padding(.vertical, 8)
            .background(.bar)
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button("Take Photo", systemImage: "camera") { showCamera = true }
                Button("Photo Library", systemImage: "photo.on.rectangle") {
                    showPhotoPicker = true
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title)
            }

            TextField(speech.isRecording ? "Listening…" : "Ask a follow-up", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18))
                .focused($inputFocused)
                .onChange(of: speech.transcript) {
                    guard speech.isRecording else { return }
                    draft = draftBeforeDictation.isEmpty
                        ? speech.transcript
                        : draftBeforeDictation + " " + speech.transcript
                }

            Button {
                if !speech.isRecording { draftBeforeDictation = draft }
                speech.toggle()
            } label: {
                Image(systemName: speech.isRecording ? "mic.circle.fill" : "mic.circle")
                    .font(.title)
                    .foregroundStyle(speech.isRecording ? .red : .accentColor)
            }

            if store.isGenerating {
                Button {
                    store.stopGenerating()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                }
            } else {
                Button {
                    if speech.isRecording { speech.stop() }
                    store.send(draft)
                    draft = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
    }

    /// Shown while the brain downloads or wakes up. The live progress is in
    /// the Brain section above; this just keeps the content area calm.
    private var preparingScreen: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(
                store.isDownloaded(store.currentModelID)
                    ? "Waking up \(store.modelName)…"
                    : "Downloading \(store.modelName)…"
            )
            .font(.headline)
            Text(
                "First time takes a few minutes on Wi-Fi. After that it's instant and works with no signal."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            Spacer()
        }
    }

    private func failureScreen(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Couldn't load \(store.modelName)")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                store.downloadModel(store.currentModelID)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }
}
