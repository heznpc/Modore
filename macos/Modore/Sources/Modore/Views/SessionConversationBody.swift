import SwiftUI

/// One fetched conversation, laid out. Shared by the retirement screen and
/// the session browser so the same transcript reads the same way on both.
///
/// Display only. The judgment plane never sees this -- masking and the
/// turn cap are applied at the source, and nothing here re-requests raw.
struct SessionConversationBody: View {
    let conversation: SessionConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A transcript that is gone, unreadable, or in a format this
            // build cannot decode all arrive here with zero turns.
            // Rendering them as an empty conversation would tell someone
            // deciding what to delete that there was nothing to lose.
            if let failure = conversation.status.failureText {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if conversation.turns.isEmpty {
                Text("이 대화에는 표시할 내용이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if let first = conversation.firstUserTurn,
                   conversation.omittedTurns > 0 {
                    Text("시작: \(first)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Divider()
                }
                ForEach(conversation.turns) { turn in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(turn.speakerLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(turn.isUser ? Color.primary : Color.secondary)
                        Text(turn.text)
                            .font(.caption)
                            .foregroundStyle(turn.isUser ? Color.primary : Color.secondary)
                            .textSelection(.enabled)
                    }
                }
                if conversation.omittedTurns > 0 {
                    Text("이전 \(conversation.omittedTurns)개 턴은 생략됨. 대화 내보내기는 텍스트만 포함하며, 도구 기록은 원본 백업이 필요합니다.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}
