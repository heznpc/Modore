import Foundation

extension ScanModel {
    func loadRecoveryHistory() {
        do {
            recoveryHistory = try RecoveryHistoryStore.load(in: projectRoot).map(\.afterRestart)
            recoveryHistoryError = nil
        } catch {
            recoveryHistoryError = "계획 이력을 읽지 못했습니다. 기존 기록은 보존하며, 이력을 저장할 수 있을 때까지 새 계획 실행을 차단합니다."
        }
    }

    @discardableResult
    func saveRecoveryHistory(_ record: RecoveryHistory) -> Bool {
        do {
            // Keep the restart interpretation for earlier unfinished records.
            let previous = Dictionary(uniqueKeysWithValues: recoveryHistory.map { ($0.id, $0) })
            recoveryHistory = try recoveryHistoryWriter(record, projectRoot).map {
                $0.id == record.id ? $0 : (previous[$0.id] ?? $0.afterRestart)
            }
            recoveryHistoryError = nil
            return true
        } catch {
            let message = "계획 이력을 저장하지 못해 남은 실행을 중단했습니다. 기존 기록과 개별 정리 영수증을 확인하세요."
            recoveryHistoryError = message
            errorMessage = message
            appendLog(message)
            return false
        }
    }
}
