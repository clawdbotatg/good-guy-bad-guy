import PhotosUI
import SwiftUI

struct ChatView: View {
    let store: ChatStore
    @State private var draft = ""
    @State private var speech = SpeechRecognizer()
    @State private var draftBeforeDictation = ""
    @State private var pendingImage: UIImage?
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var downloadStartedAt: Date?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch store.modelState {
                case .ready:
                    messageList
                    composer
                case .idle, .downloading:
                    loadingScreen
                case .failed(let message):
                    failureScreen(message)
                }
            }
            .navigationTitle("Good Guy Bad Guy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Chat", systemImage: "square.and.pencil") {
                        store.clear()
                    }
                    .disabled(store.messages.isEmpty)
                }
            }
        }
        .task {
            await store.loadModel()
            // Demo hook for automated simulator screenshots: launch with
            // SIMCTL_CHILD_GGBG_DEMO=1 to auto-send a photo so the verdict
            // banner renders without driving taps.
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
            CameraPicker { pendingImage = $0 }
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) {
            guard let photoItem else { return }
            Task {
                if let data = try? await photoItem.loadTransferable(type: Data.self),
                    let image = UIImage(data: data)
                {
                    pendingImage = image
                }
                self.photoItem = nil
            }
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
                "Found a snake, spider, bug, plant, or mushroom? Snap a photo and the on-device model tells you if it's dangerous — works with zero bars."
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
            Text("Running \(store.modelName)\nentirely on this device.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
        .padding(.top, 48)
        .padding(.horizontal, 24)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let pendingImage {
                HStack {
                    Image(uiImage: pendingImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                self.pendingImage = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .offset(x: 6, y: -6)
                        }
                    Spacer()
                }
                .padding(.horizontal)
            }
            composerRow
        }
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

            TextField(speech.isRecording ? "Listening…" : "Message", text: $draft, axis: .vertical)
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
                    store.send(draft, image: pendingImage)
                    draft = ""
                    pendingImage = nil
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(
                    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && pendingImage == nil)
            }
        }
        .padding(.horizontal)
    }

    private var loadingScreen: some View {
        VStack(spacing: 16) {
            Spacer()
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                // The weights are one giant file, so the real byte fraction can
                // sit still for minutes. Sweep to 90% over the first minute and
                // crawl after; the real fraction wins whenever it's ahead.
                let real: Double =
                    if case .downloading(let fraction) = store.modelState {
                        fraction
                    } else { 0 }
                let elapsed =
                    downloadStartedAt.map { context.date.timeIntervalSince($0) } ?? 0
                let sweep =
                    elapsed < 60
                    ? elapsed / 60 * 0.90
                    : 0.90 + min((elapsed - 60) / 300, 1) * 0.09
                let displayed = min(max(real, sweep), 0.99)
                ProgressView(value: displayed) {
                    Text("Downloading model…")
                } currentValueLabel: {
                    Text("\(Int(displayed * 100))% of \(store.modelName)")
                }
                .padding(.horizontal, 40)
            }
            Text("One-time download — after this, everything runs offline.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .onAppear {
            if downloadStartedAt == nil { downloadStartedAt = Date() }
        }
    }

    private func failureScreen(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Couldn't load the model")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                Task { await store.loadModel() }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }
}
