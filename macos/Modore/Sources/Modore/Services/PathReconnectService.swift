import Foundation

enum PathReconnectService {
    static func inventory(projectRoot: URL) async -> Result<PathReconnectInventory, SessionRecoveryFailure> {
        await request(projectRoot: projectRoot, arguments: ["list"]) { data in
            let value = try JSONDecoder().decode(PathReconnectInventory.self, from: data)
            guard value.valid else { throw invalidResponse() }
            return value
        }
    }

    static func preview(projectRoot: URL, original: URL, target: URL) async -> Result<PathReconnectPlan, SessionRecoveryFailure> {
        await request(projectRoot: projectRoot, arguments: ["preview", "--original", original.path, "--target", target.path]) { data in
            let value = try JSONDecoder().decode(PathReconnectPlan.self, from: data)
            guard value.matches(original: original, target: target) else { throw invalidResponse() }
            return value
        }
    }

    static func connect(projectRoot: URL, plan: PathReconnectPlan) async -> Result<PathReconnectConnection, SessionRecoveryFailure> {
        guard plan.matches(original: URL(fileURLWithPath: plan.originalPath), target: URL(fileURLWithPath: plan.targetPath)),
              Date().timeIntervalSince1970 < plan.expiresAt else { return .failure(invalidResponse()) }
        return await request(projectRoot: projectRoot, arguments: ["connect", "--plan-id", plan.planID, "--owner-approved"]) { data in
            let value = try JSONDecoder().decode(PathReconnectConnection.self, from: data)
            guard value.matches(plan) else { throw invalidResponse() }
            return value
        }
    }

    static func disconnect(projectRoot: URL, connection: PathReconnectConnection) async -> Result<PathReconnectConnection, SessionRecoveryFailure> {
        guard connection.valid, connection.canDisconnect else { return .failure(invalidResponse()) }
        return await request(projectRoot: projectRoot, arguments: ["undo", "--connection-id", connection.connectionID, "--owner-approved"]) { data in
            let value = try JSONDecoder().decode(PathReconnectConnection.self, from: data)
            guard value.confirmsUndo(of: connection) else { throw invalidResponse() }
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
                script: "path_reconnect.py", arguments: arguments, timeout: 600)
            return .success(try decode(SessionRecoveryService.validatedData(result)))
        } catch { return .failure(.init(message: error.localizedDescription)) }
    }

    private static func invalidResponse() -> SessionRecoveryFailure {
        .init(message: L10n.text("재연결 결과가 선택한 경로와 일치하지 않거나 만료됐습니다. 다시 확인하세요."))
    }
}
