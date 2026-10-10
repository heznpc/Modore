import SwiftUI

struct RetirementImpactStatusView: View {
    let outcome: ScreeBindOutcome?
    let observedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let outcome {
                Text(summary(outcome)).font(.caption)
                if let observedAt {
                    Text(observedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
                if let diagnostic = outcome.diagnostic {
                    Text(diagnostic).font(.caption).foregroundStyle(.secondary)
                }
                if case .bindings(let sessions, _) = outcome.assessment, !sessions.isEmpty {
                    DisclosureGroup(L10n.text("발견한 대화 파일")) {
                        ForEach(Array(sessions.prefix(RetirementPresentation.boundSessionDisplayLimit).enumerated()), id: \.offset) { _, session in
                            Text(session.source.path).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if sessions.count > RetirementPresentation.boundSessionDisplayLimit {
                            Text(L10n.format("처음 %@개 표시 · 전체 %@개", String(RetirementPresentation.boundSessionDisplayLimit), String(sessions.count)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(L10n.text("대화 영향 미확인")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ outcome: ScreeBindOutcome) -> String {
        switch outcome.coverage {
        case .complete:
            return L10n.format("조사 범위 확인 · 발견 대화 %@개", String(outcome.sessionCount))
        case .partial:
            return L10n.format("부분 확인 · 발견 대화 %@개 · 추가 연결은 미확인", String(outcome.sessionCount))
        case .unknown:
            return L10n.text("대화 영향 미확인")
        }
    }
}
