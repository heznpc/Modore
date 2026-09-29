import Foundation

enum BackupReclaimService {
    static func compare(projectRoot: URL, local: URL, backup: URL) async -> Result<BackupReclaimPlan, SessionRecoveryFailure> {
        await request(projectRoot: projectRoot, arguments: ["compare", "--local", local.path, "--backup", backup.path]) { data in
            let value = try JSONDecoder().decode(BackupReclaimPlan.self, from: data)
            guard value.matches(local: local, backup: backup) else { throw invalidResponse() }
            return value
        }
    }

    static func delete(projectRoot: URL, plan: BackupReclaimPlan, selected: Set<String>) async -> Result<BackupReclaimReceipt, SessionRecoveryFailure> {
        guard !selected.isEmpty, selected.count <= 1_000,
              selected.isSubset(of: Set(plan.rows.filter(\.selectable).map(\.id))),
              Date().timeIntervalSince1970 < plan.expiresAt else { return .failure(invalidResponse()) }
        return await request(projectRoot: projectRoot,
            arguments: ["delete", "--plan-id", plan.planID, "--owner-approved", "--selected"] + selected.sorted()) { data in
            let value = try JSONDecoder().decode(BackupReclaimReceipt.self, from: data)
            guard value.matches(plan, selected: selected) else { throw invalidResponse() }
            return value
        }
    }

    private static func request<Value>(projectRoot: URL, arguments: [String],
                                      decode: (Data) throws -> Value) async -> Result<Value, SessionRecoveryFailure> {
        guard let execution = await RuntimeWorkspace.prepareExecutionAsync(projectRoot: projectRoot) else {
            return .failure(.init(message: L10n.text("서명된 실행 런타임을 확인하지 못했습니다.")))
        }
        do {
            let result = try await SessionRecoveryService.invoke(execution: execution,
                script: "backup_reclaim.py", arguments: arguments, timeout: 7_200)
            return .success(try decode(SessionRecoveryService.validatedData(result)))
        } catch { return .failure(.init(message: error.localizedDescription)) }
    }

    private static func invalidResponse() -> SessionRecoveryFailure {
        .init(message: L10n.text("비교 결과가 선택한 폴더·파일과 일치하지 않거나 만료됐습니다. 다시 비교하세요."))
    }
}
