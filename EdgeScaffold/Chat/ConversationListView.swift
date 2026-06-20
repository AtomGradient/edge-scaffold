// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import SwiftUI
import EdgeSession

struct ConversationListView: View {
    @ObservedObject var store: ConversationStore
    let onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.conversations.isEmpty {
                    ContentUnavailableView(
                        "No Conversations",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start a chat to see your history here.")
                    )
                } else {
                    List {
                        ForEach(store.conversations) { conv in
                            Button {
                                onSelect(conv.id)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(conv.title)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(conv.modelCategory.uppercased())
                                            .font(.caption2.bold())
                                            .foregroundStyle(categoryColor(conv.modelCategory))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(categoryColor(conv.modelCategory).opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                    HStack {
                                        Text(conv.updatedAt, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(conv.messageCount) messages")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { indexSet in
                            deleteConversations(at: indexSet)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !store.conversations.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func deleteConversations(at indexSet: IndexSet) {
        let ids = indexSet.compactMap { index in
            store.conversations.indices.contains(index) ? store.conversations[index].id : nil
        }
        Task { @MainActor in
            for id in ids {
                try? await store.deleteConversation(id)
            }
        }
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "llm": .blue
        case "vlm": .purple
        case "tts": .green
        case "stt": .orange
        default: .gray
        }
    }
}
