// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import AVFoundation
import EdgeInference
import EdgeSession
import EdgeUI
import MarkdownUI

enum MessageRole: String, Codable, Sendable {
    case system, user, assistant

    var chatRole: ChatMessage.Role {
        switch self {
        case .system: .system
        case .user: .user
        case .assistant: .assistant
        }
    }

    init(_ role: ChatMessage.Role) {
        switch role {
        case .system: self = .system
        case .user: self = .user
        case .assistant: self = .assistant
        case .tool: self = .assistant
        }
    }
}

struct DisplayMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    var imageData: Data?
    var feedbackRating: String?  // "good" / "bad"

    var audioSamples: [Float]?
    var sampleRate: Int?

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, imageData, feedbackRating
    }

    init(
        id: UUID = UUID(),
        role: ChatMessage.Role,
        content: String,
        timestamp: Date = Date(),
        imageData: Data? = nil,
        feedbackRating: String? = nil,
        audioSamples: [Float]? = nil,
        sampleRate: Int? = nil
    ) {
        self.id = id
        self.role = MessageRole(role)
        self.content = content
        self.timestamp = timestamp
        self.imageData = imageData
        self.feedbackRating = feedbackRating
        self.audioSamples = audioSamples
        self.sampleRate = sampleRate
    }
}

extension DisplayMessage {
    init(from edge: EdgeConversationMessage) {
        self.init(
            id: edge.id,
            role: edge.role.chatRole,
            content: edge.content,
            timestamp: edge.timestamp,
            imageData: edge.metadata["imageDataBase64"].flatMap { Data(base64Encoded: $0) },
            feedbackRating: edge.metadata["feedbackRating"]
        )
    }

    func toEdgeConversationMessage() -> EdgeConversationMessage {
        var metadata: [String: String] = [:]
        if let imageData {
            metadata["imageDataBase64"] = imageData.base64EncodedString()
        }
        if let feedbackRating {
            metadata["feedbackRating"] = feedbackRating
        }
        return EdgeConversationMessage(
            id: id,
            role: EdgeConversationRole(from: role.chatRole),
            content: content,
            timestamp: timestamp,
            metadata: metadata
        )
    }
}


enum ChatTheme {
    static let accent = Color.indigo
    static let userGradient = LinearGradient(
        colors: [Color.indigo, Color.indigo.opacity(0.82)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let bubbleRadius: CGFloat = 18
}


struct MessageBubble: View {
    let message: DisplayMessage
    var onFeedback: ((String) -> Void)?

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 8) {
                    if let imageData = message.imageData, let uiImage = UIImage(data: imageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if let samples = message.audioSamples, let sampleRate = message.sampleRate {
                        AudioPlayButton(samples: samples, sampleRate: sampleRate)
                    }

                    if !message.content.isEmpty {
                        if isUser {
                            Text(message.content)
                                .font(.body)
                        } else {
                            Markdown(message.content)
                                .markdownTextStyle {
                                    ForegroundColor(.primary)
                                }
                        }
                    }
                }
                .padding(12)
                .background {
                    if isUser {
                        ChatTheme.userGradient
                    } else {
                        RoundedRectangle(cornerRadius: ChatTheme.bubbleRadius)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: ChatTheme.bubbleRadius)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                            )
                    }
                }
                .foregroundStyle(isUser ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: ChatTheme.bubbleRadius))
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.content
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: message.content) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }

                HStack(spacing: 8) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if message.role == .assistant {
                        Spacer()
                        if let onFeedback {
                            Button { onFeedback("good") } label: {
                                Image(systemName: message.feedbackRating == "good" ? "hand.thumbsup.fill" : "hand.thumbsup")
                                    .font(.caption)
                                    .foregroundStyle(message.feedbackRating == "good" ? .green : .secondary)
                            }
                            .buttonStyle(.plain)

                            Button { onFeedback("bad") } label: {
                                Image(systemName: message.feedbackRating == "bad" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                    .font(.caption)
                                    .foregroundStyle(message.feedbackRating == "bad" ? .red : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }
}


struct ScaffoldTranscriptRow: View {
    let message: DisplayMessage
    var onFeedback: ((String) -> Void)?

    private var isUser: Bool { message.role == .user }
    private var roleTitle: String { isUser ? "You" : "Assistant" }
    private var roleIcon: String { isUser ? "person.crop.circle" : "sparkles" }
    private var accentColor: Color { isUser ? .primary.opacity(0.68) : ChatTheme.accent }

    var body: some View {
        EdgeAgentTranscriptRow(
            title: roleTitle,
            systemImage: roleIcon,
            timestamp: message.timestamp,
            accentColor: accentColor,
            sideBarOpacity: isUser ? 0.18 : 0.45,
            copyText: message.content
        ) {
            if message.role == .assistant {
                assistantActions
            }
        } toolTraceContent: {
            EmptyView()
        } content: {
            contentView
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if let imageData = message.imageData, let uiImage = UIImage(data: imageData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if let samples = message.audioSamples, let sampleRate = message.sampleRate {
            AudioPlayButton(samples: samples, sampleRate: sampleRate)
        }

        if !message.content.isEmpty {
            if isUser {
                Text(message.content)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else {
                Markdown(message.content)
                    .markdownTextStyle {
                        FontSize(15)
                    }
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var assistantActions: some View {
        HStack(spacing: 10) {
            if let onFeedback {
                Button { onFeedback("good") } label: {
                    Image(systemName: message.feedbackRating == "good" ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.caption)
                        .foregroundStyle(message.feedbackRating == "good" ? .green : .secondary)
                }
                .buttonStyle(.plain)

                Button { onFeedback("bad") } label: {
                    Image(systemName: message.feedbackRating == "bad" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.caption)
                        .foregroundStyle(message.feedbackRating == "bad" ? .red : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}


struct ThinkingIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isAnimating ? 1.0 : 0.5)
                    .opacity(isAnimating ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.2),
                        value: isAnimating
                    )
            }
        }
        .padding(.vertical, 4)
        .onAppear { isAnimating = true }
    }
}
