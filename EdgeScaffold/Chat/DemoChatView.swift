// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import Foundation
import CoreImage
import EdgeInference
import EdgeSession
import EdgeUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

typealias ScaffoldActivityStatus = EdgeActivityStatus

extension EdgeActivityStatus {
    static let scaffoldIdle = EdgeActivityStatus(
        title: "Ready",
        detail: "Inference is available",
        systemImage: "checkmark.circle",
        actionLabel: "Ready"
    )

    static let scaffoldThinking = EdgeActivityStatus(
        title: "推理中",
        detail: "Local model",
        systemImage: "sparkles",
        actionLabel: "正在推理"
    )

    static let scaffoldAnswering = EdgeActivityStatus(
        title: "输出中",
        detail: "Streaming answer",
        systemImage: "text.bubble",
        actionLabel: "正在输出"
    )

    static let scaffoldJointInference = EdgeActivityStatus(
        title: "联合推理中",
        detail: "EdgeStudio host model",
        systemImage: "desktopcomputer",
        actionLabel: "正在推理"
    )

    static let scaffoldListening = EdgeActivityStatus(
        title: "Transcribing",
        detail: "Speech model",
        systemImage: "waveform",
        actionLabel: "Transcribing"
    )

    static let scaffoldSpeaking = EdgeActivityStatus(
        title: "Generating audio",
        detail: "Voice model",
        systemImage: "speaker.wave.2",
        actionLabel: "Generating audio"
    )
}

struct DemoChatView: View {
    @EnvironmentObject var aiManager: AIManager
    @EnvironmentObject var meshManager: MeshManager
    @StateObject private var conversationStore = ConversationStore.shared
    @StateObject var chatSession = ChatSessionController(client: AIManager.shared)
    @FocusState private var isInputFocused: Bool

    @State var inputText = ""
    @State var messages: [DisplayMessage] = []
    @State private var correctionFlowState = ChatFeedbackFlow.CorrectionDraftState.empty
    @State var isGenerating = false
    @State var currentResponse = ""
    @State var tokensPerSecond: Double = 0
    @State var activityStatus = ScaffoldActivityStatus.scaffoldIdle
    @State var activityStartedAt: Date?
    @State var activityOutputTokens = 0
    @State var generationTask: Task<Void, Never>?
    @State var activeGenerationID: UUID?
    @State var enableThinking = ScaffoldConfig.defaultEnableThinking

    @State var chatHistory: [ChatMessage] = []

    @State var currentConversationID: UUID?
    @State var showConversationList = false
    @State private var showCorrectionSheet = false
    @State private var correctionTargetIndex: Int?
    @State private var correctionDraft = ""
    @State private var lastAutoScrollAt = Date.distantPast

    @State var selectedPhoto: PhotosPickerItem?
    @State var selectedCIImage: CIImage?
    @State var selectedImageData: Data?

    @State var audioPlayer: AVAudioPlayer?
    @State var isPlaying = false
    @State var selectedVoice: String?
    @State var instructText: String = "A gentle female voice with clear pronunciation"

    @State var audioRecorder: AVAudioRecorder?
    @State var isRecording = false
    @State var recordingURL: URL?
    @State var showAudioFilePicker = false

    @State private var showScrollToBottom = false

    var modelCategory: ModelCategory { aiManager.modelCategory }
    var latestAssistantMessageIndex: Int? {
        messages.indices.last { messages[$0].role == .assistant }
    }
    var inferenceReady: Bool {
        aiManager.isModelLoaded || (modelCategory == .llm && meshManager.canUseJointInference)
    }

    var canSend: Bool {
        guard inferenceReady, !isGenerating else { return false }
        if modelCategory == .stt { return true }
        return !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if messages.isEmpty && !isGenerating {
                                emptyStateView
                            }

                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                                ScaffoldTranscriptRow(message: msg, onFeedback: msg.role == .assistant ? { rating in
                                    handleFeedback(for: index, rating: rating)
                                } : nil)
                            }

                            if isGenerating {
                                streamingWorkbench
                                    .id("streaming")
                            }

                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding()
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: currentResponse) {
                        guard isGenerating else { return }
                        guard Date().timeIntervalSince(lastAutoScrollAt) >= 0.18 else { return }
                        lastAutoScrollAt = Date()
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                    .onChange(of: messages.count) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if showScrollToBottom && !isGenerating {
                            Button {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            } label: {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(ChatTheme.accent)
                                    .padding(8)
                                    .background(.regularMaterial, in: Circle())
                                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, 8)
                        }
                    }
                }

                if inferenceReady {
                    statusBar
                }

                if modelCategory == .vlm, let imageData = selectedImageData,
                   let uiImage = UIImage(data: imageData) {
                    HStack {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button { clearSelectedImage() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                ttsVoicePicker

                inputBar
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onTapGesture {
                isInputFocused = false
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 4) {
                        Button { startNewChat() } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .disabled(isGenerating)

                        Button { showConversationList = true } label: {
                            Image(systemName: "list.bullet")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !aiManager.isModelLoaded {
                        Button("Load Model") {
                            Task { await aiManager.loadSelectedModel() }
                        }
                    }
                }
            }
            .sheet(isPresented: $showConversationList) {
                ConversationListView(store: conversationStore) { conversationID in
                    loadConversation(conversationID)
                }
            }
            .sheet(isPresented: $showCorrectionSheet, onDismiss: resetCorrectionDraft) {
                correctionSheet
            }
            .fileImporter(
                isPresented: $showAudioFilePicker,
                allowedContentTypes: [.audio, .mp3, .wav, .aiff, .mpeg4Audio],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    handleImportedAudio(url: url)
                }
            }
            .task {
                try? await conversationStore.loadConversations()
            }
        }
    }

    private var correctionSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $correctionDraft)
                        .frame(minHeight: 160)
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))

                    if correctionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Describe the correct behavior")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Correction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showCorrectionSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let index = correctionTargetIndex {
                            submitCorrection(for: index, correctionText: correctionDraft)
                        }
                        showCorrectionSheet = false
                    }
                    .disabled(correctionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }


    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 60)

            Image(systemName: categoryIcon)
                .font(.system(size: 40))
                .foregroundStyle(ChatTheme.accent.opacity(0.4))

            Text(aiManager.loadedModelName ?? ScaffoldConfig.modelDisplayName)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            if modelCategory == .llm || modelCategory == .vlm {
                VStack(spacing: 10) {
                    ForEach(suggestedPrompts, id: \.self) { prompt in
                        Button {
                            inputText = prompt
                            isInputFocused = true
                        } label: {
                            HStack {
                                Text(prompt)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary.opacity(0.7))
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var categoryIcon: String {
        switch modelCategory {
        case .llm: "bubble.left.and.text.bubble.right"
        case .vlm: "eye.circle"
        case .tts: "waveform"
        case .stt: "mic"
        }
    }

    private var suggestedPrompts: [String] {
        switch modelCategory {
        case .llm: [
            "Explain quantum computing in simple terms",
            "Write a haiku about technology",
            "What are 3 tips for better sleep?",
        ]
        case .vlm: [
            "Describe what you see in detail",
            "What colors are prominent?",
            "Is there any text in this image?",
        ]
        default: []
        }
    }


    @ViewBuilder
    private var streamingWorkbench: some View {
        EdgeAgentWorkbench(accentColor: ChatTheme.accent) {
            scaffoldActivityStatusStrip
        } toolTraceContent: {
            EmptyView()
        } responseContent: {
            if !currentResponse.isEmpty {
                Text(currentResponse)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.leading, 26)
            }
        }
    }

    private var scaffoldActivityStatusStrip: some View {
        EdgeActivityStatusView(
            status: activityStatus,
            startedAt: activityStartedAt,
            compact: !currentResponse.isEmpty,
            outputTokens: activityOutputTokens,
            isActive: activityStatus != .scaffoldIdle,
            accentColor: ChatTheme.accent,
            motion: .lightweight
        )
    }


    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)

            Text(aiManager.loadedModelName ?? (meshManager.canUseJointInference ? "Mac Joint Inference" : "Ready"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(modelCategory.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(categoryColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(categoryColor.opacity(0.12))
                .clipShape(Capsule())

            if meshManager.canUseJointInference {
                Text("JOINT")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.indigo.opacity(0.12))
                    .clipShape(Capsule())
            }

            Spacer()

            if isGenerating {
                compactScaffoldActivityLabel
            }

            if modelCategory == .llm || modelCategory == .vlm {
                Toggle("Think", isOn: $enableThinking)
                    .toggleStyle(.switch)
                    .font(.caption)
                    .fixedSize()
                    .disabled(isGenerating)
            }

            if !isGenerating && tokensPerSecond > 0 && modelCategory != .tts && modelCategory != .stt {
                Text(String(format: "%.1f tok/s", tokensPerSecond))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(tpsColor)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    private var compactScaffoldActivityLabel: some View {
        EdgeActivityStatusView(
            status: activityStatus,
            startedAt: activityStartedAt,
            compact: true,
            outputTokens: activityOutputTokens,
            isActive: activityStatus != .scaffoldIdle,
            accentColor: ChatTheme.accent,
            motion: .lightweight
        )
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private var tpsColor: Color {
        if tokensPerSecond >= 15 { return .green }
        if tokensPerSecond >= 8 { return .blue }
        return .secondary
    }


    private var inputBar: some View {
        HStack(spacing: 12) {
            if modelCategory == .vlm {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(ChatTheme.accent)
                }
                .onChange(of: selectedPhoto) { _, newValue in
                    Task { await loadSelectedPhoto(newValue) }
                }
            }

            if modelCategory == .stt {
                Button { showAudioFilePicker = true } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.title3)
                        .foregroundStyle(ChatTheme.accent)
                }
                .disabled(isGenerating)

                Button { toggleRecording() } label: {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title)
                        .foregroundStyle(isRecording ? .red : ChatTheme.accent)
                }
                .disabled(isGenerating)
            }

            if modelCategory != .stt {
                TextField(placeholder, text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(
                                        isInputFocused ? ChatTheme.accent.opacity(0.4) : Color.primary.opacity(0.08),
                                        lineWidth: isInputFocused ? 1 : 0.5
                                    )
                            )
                    )
                    .animation(.easeInOut(duration: 0.2), value: isInputFocused)
            } else {
                Text(isRecording ? "Recording..." : placeholder)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }

            if isGenerating {
                Button {
                    cancelGeneration()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("Stop generation")
            } else if modelCategory != .stt {
                Button { sendMessage() } label: {
                    Image(systemName: modelCategory == .tts ? "speaker.wave.2.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? ChatTheme.accent : .secondary.opacity(0.5))
                }
                .disabled(!canSend)
            }
        }
        .padding()
        .background(.thinMaterial)
    }


    @ViewBuilder
    private var ttsVoicePicker: some View {
        if modelCategory == .tts {
            if aiManager.ttsModelType == "voice_design" {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "waveform.and.person.filled")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text("Voice Description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("Describe the voice style...", text: $instructText, axis: .vertical)
                        .font(.caption)
                        .lineLimit(1...3)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal)
                .padding(.top, 6)
            } else if !aiManager.availableSpeakers.isEmpty {
                HStack {
                    Image(systemName: "person.wave.2")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(aiManager.availableSpeakers, id: \.self) { voice in
                                Button { selectedVoice = voice } label: {
                                    Text(voice.capitalized)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            (selectedVoice ?? aiManager.availableSpeakers.first) == voice
                                                ? ChatTheme.accent
                                                : Color(.systemGray5)
                                        )
                                        .foregroundStyle(
                                            (selectedVoice ?? aiManager.availableSpeakers.first) == voice
                                                ? .white : .primary
                                        )
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 6)
            }
        }
    }


    private var placeholder: String {
        switch modelCategory {
        case .llm: "Ask anything..."
        case .vlm: "Ask about the image..."
        case .tts: "Enter text to speak..."
        case .stt: "Tap mic to record..."
        }
    }

    private var navigationTitle: String {
        switch modelCategory {
        case .llm: "Chat"
        case .vlm: "Vision Chat"
        case .tts: "Text to Speech"
        case .stt: "Speech to Text"
        }
    }

    private var categoryColor: Color {
        switch modelCategory {
        case .llm: .blue
        case .vlm: .purple
        case .tts: .green
        case .stt: .orange
        }
    }


    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        isInputFocused = false

        switch modelCategory {
        case .llm: startLLMGeneration(text: text)
        case .vlm: startVLMGeneration(text: text)
        case .tts: startTTSGeneration(text: text)
        case .stt: break
        }
    }

    func beginActivity(_ status: ScaffoldActivityStatus) {
        activityStatus = status
        activityStartedAt = Date()
        activityOutputTokens = 0
    }

    func setActivityStatus(_ status: ScaffoldActivityStatus) {
        if activityStatus != status {
            activityStatus = status
        }
    }

    func updateActivityOutputTokens(_ count: Int) {
        activityOutputTokens = max(0, count)
    }

    func endActivity() {
        activityStatus = .scaffoldIdle
        activityStartedAt = nil
        activityOutputTokens = 0
    }

    func beginGeneration(status: ScaffoldActivityStatus) -> UUID {
        let id = UUID()
        activeGenerationID = id
        isGenerating = true
        currentResponse = ""
        tokensPerSecond = 0
        beginActivity(status)
        return id
    }

    func isActiveGeneration(_ id: UUID) -> Bool {
        activeGenerationID == id && isGenerating
    }

    func finishGeneration(_ id: UUID) async {
        guard activeGenerationID == id else { return }
        isGenerating = false
        currentResponse = ""
        endActivity()
        activeGenerationID = nil
        generationTask = nil
        _ = await saveCurrentConversationPersisted()
    }

    func cancelGeneration() {
        guard isGenerating else { return }
        let partial = currentResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        generationTask?.cancel()
        generationTask = nil
        activeGenerationID = nil
        chatSession.cancel(reason: "user_cancelled")
        if modelCategory != .tts && !partial.isEmpty {
            messages.append(DisplayMessage(role: .assistant, content: partial))
        }
        isGenerating = false
        currentResponse = ""
        endActivity()
        saveCurrentConversation()
    }


    func startNewChat() {
        messages = []
        chatHistory = []
        currentResponse = ""
        tokensPerSecond = 0
        generationTask?.cancel()
        generationTask = nil
        activeGenerationID = nil
        activityStatus = .scaffoldIdle
        activityStartedAt = nil
        activityOutputTokens = 0
        currentConversationID = nil
        clearSelectedImage()
        chatSession.reset(reason: "new_chat")
    }

    func loadConversation(_ id: UUID) {
        startNewChat()
        currentConversationID = id
        Task { @MainActor in
            let loaded = (try? await conversationStore.loadMessages(for: id)) ?? []
            messages = loaded.map(DisplayMessage.init(from:))

            chatHistory = []
            chatHistory.append(.system(ScaffoldConfig.defaultSystemPrompt))
            for msg in messages {
                switch msg.role {
                case .user: chatHistory.append(.user(msg.content))
                case .assistant: chatHistory.append(.assistant(msg.content))
                case .system: break
                }
            }
            chatSession.replaceHistory(chatHistory)
        }
    }

    @MainActor
    func saveCurrentConversationPersisted() async -> (conversationID: UUID?, messageCount: Int, saved: Bool) {
        let snapshot = messages
        guard !snapshot.isEmpty else {
            return (currentConversationID, 0, false)
        }
        do {
            if currentConversationID == nil {
                let conv = try await conversationStore.createConversation(
                    title: "New Chat",
                    modelCategory: modelCategory.rawValue
                )
                currentConversationID = conv.id
            }
            if let currentConversationID {
                try await conversationStore.saveMessages(
                    snapshot.map { $0.toEdgeConversationMessage() },
                    for: currentConversationID
                )
                return (currentConversationID, snapshot.count, true)
            }
        } catch {
            NSLog("[ConversationStore] save failed: \(error)")
        }
        return (currentConversationID, snapshot.count, false)
    }

    @MainActor
    func ensureCurrentConversationIDForJointInference() async -> UUID? {
        if let currentConversationID {
            return currentConversationID
        }
        do {
            let conv = try await conversationStore.createConversation(
                title: "New Chat",
                modelCategory: modelCategory.rawValue
            )
            currentConversationID = conv.id
            return conv.id
        } catch {
            NSLog("[ScaffoldJointInference] create conversation failed: \(error)")
            return nil
        }
    }

    func saveCurrentConversation() {
        Task { @MainActor in
            _ = await saveCurrentConversationPersisted()
        }
    }


    private func handleFeedback(for messageIndex: Int, rating: String) {
        let result = ChatFeedbackFlow.applyFeedback(
            rating: rating,
            messageIndex: messageIndex,
            messages: messages,
            correctionState: correctionFlowState
        )
        messages = result.messages
        correctionFlowState = result.correctionState
        if let feedback = result.feedback {
            PersonalizationManager.shared.recordFeedback(feedback)
            saveCurrentConversation()
        }
        if result.didOpenCorrectionEditor {
            correctionTargetIndex = result.correctionState.targetIndex
            correctionDraft = result.correctionState.draft
            showCorrectionSheet = result.correctionState.isPresented
        }
    }

    private func resetCorrectionDraft() {
        correctionFlowState = ChatFeedbackFlow.resetCorrectionState()
        correctionTargetIndex = nil
        correctionDraft = ""
    }

    private func submitCorrection(for messageIndex: Int, correctionText: String) {
        let result = ChatFeedbackFlow.submitCorrection(
            messageIndex: messageIndex,
            correctionText: correctionText,
            messages: messages
        )
        messages = result.messages
        if let feedback = result.feedback {
            PersonalizationManager.shared.recordFeedback(feedback)
        }
        if let correction = result.correction {
            PersonalizationManager.shared.recordCorrection(correction)
        }
        if result.feedback != nil || result.correction != nil {
            saveCurrentConversation()
        }
    }
}
