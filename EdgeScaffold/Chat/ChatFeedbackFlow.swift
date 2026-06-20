// Copyright © 2026 AtomGradient
// 版权所有 © 2026 质子梯度（北京）科技有限公司

import Foundation
import EdgeSession

@MainActor
enum ChatFeedbackFlow {
    struct CorrectionDraftState: Equatable {
        var targetIndex: Int?
        var draft: String
        var isPresented: Bool

        static let empty = CorrectionDraftState(
            targetIndex: nil,
            draft: "",
            isPresented: false
        )
    }

    struct FeedbackResult {
        var messages: [DisplayMessage]
        let feedback: ChatFeedback?
        let correction: ChatCorrection?
        let correctionState: CorrectionDraftState
        let didOpenCorrectionEditor: Bool
    }

    static func applyFeedback(
        rating: String,
        messageIndex: Int,
        messages: [DisplayMessage],
        correctionState: CorrectionDraftState
    ) -> FeedbackResult {
        guard messages.indices.contains(messageIndex) else {
            return FeedbackResult(
                messages: messages,
                feedback: nil,
                correction: nil,
                correctionState: correctionState,
                didOpenCorrectionEditor: false
            )
        }
        if rating == "bad" {
            var state = correctionState
            state.targetIndex = messageIndex
            state.draft = messages[messageIndex].content
            state.isPresented = true
            return FeedbackResult(
                messages: messages,
                feedback: nil,
                correction: nil,
                correctionState: state,
                didOpenCorrectionEditor: true
            )
        }

        var nextMessages = messages
        nextMessages[messageIndex].feedbackRating = rating
        return FeedbackResult(
            messages: nextMessages,
            feedback: feedbackRecord(
                messages: nextMessages,
                messageIndex: messageIndex,
                rating: rating
            ),
            correction: nil,
            correctionState: correctionState,
            didOpenCorrectionEditor: false
        )
    }

    static func submitCorrection(
        messageIndex: Int,
        correctionText: String,
        messages: [DisplayMessage]
    ) -> FeedbackResult {
        guard messages.indices.contains(messageIndex) else {
            return FeedbackResult(
                messages: messages,
                feedback: nil,
                correction: nil,
                correctionState: .empty,
                didOpenCorrectionEditor: false
            )
        }

        var nextMessages = messages
        nextMessages[messageIndex].feedbackRating = "bad"
        let feedback = feedbackRecord(
            messages: nextMessages,
            messageIndex: messageIndex,
            rating: "bad"
        )
        let correction = correctionRecord(
            messages: nextMessages,
            messageIndex: messageIndex,
            correctionText: correctionText
        )
        return FeedbackResult(
            messages: nextMessages,
            feedback: feedback,
            correction: correction,
            correctionState: .empty,
            didOpenCorrectionEditor: false
        )
    }

    static func resetCorrectionState() -> CorrectionDraftState {
        .empty
    }

    private static func feedbackRecord(
        messages: [DisplayMessage],
        messageIndex: Int,
        rating: String
    ) -> ChatFeedback? {
        guard messages.indices.contains(messageIndex),
              let userIndex = messages[..<messageIndex].lastIndex(where: { $0.role == .user })
        else {
            return nil
        }
        return ChatFeedback(
            userMessage: messages[userIndex].content,
            assistantResponse: messages[messageIndex].content,
            rating: rating == "good" ? .good : .bad
        )
    }

    private static func correctionRecord(
        messages: [DisplayMessage],
        messageIndex: Int,
        correctionText: String
    ) -> ChatCorrection? {
        let trimmed = correctionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              messages.indices.contains(messageIndex),
              let userIndex = messages[..<messageIndex].lastIndex(where: { $0.role == .user })
        else {
            return nil
        }
        return ChatCorrection(
            sourceInputText: messages[userIndex].content,
            assistantResponse: messages[messageIndex].content,
            correctionText: trimmed
        )
    }
}
