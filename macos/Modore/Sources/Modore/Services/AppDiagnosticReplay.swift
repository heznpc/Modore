import AppKit
@preconcurrency import ApplicationServices

/// Narrow AppKit boundary. Only explicitly registered elements; never press Send/Return.
@MainActor
final class AppDiagnosticReplay: ObservableObject {
    @Published private(set) var message = "자동 재현을 쓰려면 입력창과 목록 위치를 등록하세요."
    @Published private(set) var hasInput = false
    @Published private(set) var hasHover = false
    private var input: AXUIElement?
    private var hover: AXUIElement?
    private var registration: Any?
    private var registrationTimeout: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var localEscapeMonitor: Any?
    private var owner: DiagnosticTarget?
    var onStop: (() -> Void)?

    var trusted: Bool { AXIsProcessTrusted() }
    func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        message = "시스템 설정에서 Modore 접근성을 허용한 뒤 위치를 등록하세요."
    }
    func reset() {
        cancelRegistration(); input = nil; hover = nil; owner = nil; hasInput = false; hasHover = false
    }
    func cancelRegistration() {
        if let registration { NSEvent.removeMonitor(registration) }
        registration = nil; registrationTimeout?.cancel(); registrationTimeout = nil
    }
    func register(input isInput: Bool, target: DiagnosticTarget) {
        cancelRegistration()
        guard trusted else { message = "자동 조작에는 Modore 접근성 권한이 필요합니다."; return }
        if owner != target { reset(); owner = target }
        message = isInput ? "대상 앱의 빈 입력창을 한 번 클릭하세요. 등록만 합니다." : "대상 앱의 목록에서 포인터를 옮길 곳을 한 번 클릭하세요."
        registration = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let point = CGEvent(source: nil)?.location
            Task { @MainActor in
                guard let self, let point else { return }
                self.capture(point, isInput: isInput, target: target)
            }
        }
        registrationTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            self?.cancelRegistration(); self?.message = "위치 등록 대기가 끝났습니다. 다시 등록할 수 있습니다."
        }
    }
    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name, &result) == .success ? result : nil
    }
    private func capture(_ point: CGPoint, isInput: Bool, target: DiagnosticTarget) {
        guard NativeCPUReader.read(target.pid)?.started == target.birth else { cancelRegistration(); return }
        var element: AXUIElement?
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success,
              var chosen = element else { message = "대상 앱의 접근성 요소를 읽을 수 없습니다."; return }
        var pid: pid_t = 0
        AXUIElementGetPid(chosen, &pid)
        guard pid == target.pid else { return }
        if isInput {
            for _ in 0..<8 {
                let role = attribute(chosen, kAXRoleAttribute as CFString) as? String
                if role == kAXTextAreaRole || role == kAXTextFieldRole { break }
                guard let parent = attribute(chosen, kAXParentAttribute as CFString), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                chosen = unsafeBitCast(parent, to: AXUIElement.self)
            }
            let role = attribute(chosen, kAXRoleAttribute as CFString) as? String
            guard role == kAXTextAreaRole || role == kAXTextFieldRole,
                  attribute(chosen, kAXSubroleAttribute as CFString) as? String != kAXSecureTextFieldSubrole,
                  value(chosen) == "" else { message = "접근성으로 읽을 수 있는 빈 일반 입력창을 선택하세요."; return }
            input = chosen; hasInput = true
        } else { hover = chosen; hasHover = true }
        AXUIElementSetMessagingTimeout(chosen, 0.25)
        cancelRegistration(); message = isInput ? "입력창 등록됨" : "목록 위치 등록됨"
    }
    private func value(_ element: AXUIElement) -> String? { attribute(element, kAXValueAttribute as CFString) as? String }
    private func center(_ element: AXUIElement) throws -> CGPoint {
        guard let p = attribute(element, kAXPositionAttribute as CFString), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(element, kAXSizeAttribute as CFString), CFGetTypeID(s) == AXValueGetTypeID() else { throw ReplayError.unavailable }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size), size.width > 0, size.height > 0 else { throw ReplayError.unavailable }
        return CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
    }
    private func verify(_ target: DiagnosticTarget, element: AXUIElement) throws {
        try Task.checkCancellation()
        guard owner == target, NativeCPUReader.read(target.pid)?.started == target.birth,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { throw ReplayError.changed }
        let point = try center(element)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              var hit else { throw ReplayError.unavailable }
        for _ in 0..<8 {
            if CFEqual(hit, element) { return }
            guard let parent = attribute(hit, kAXParentAttribute as CFString), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            hit = unsafeBitCast(parent, to: AXUIElement.self)
        }
        throw ReplayError.changed
    }
    func run(target: DiagnosticTarget, repeats: Int,
             mark: @escaping (String, String) async -> Void) async throws {
        guard trusted, owner == target, let input, let hover, value(input) == "" else { throw ReplayError.unavailable }
        cancelRegistration()
        installEscape()
        defer { removeEscape() }
        guard NSRunningApplication(processIdentifier: target.pid)?.activate(options: [.activateAllWindows]) == true else { throw ReplayError.changed }
        try await Task.sleep(nanoseconds: 400_000_000)
        for _ in 0..<min(3, max(1, repeats)) {
            try verify(target, element: input)
            guard value(input) == "" else { throw ReplayError.changed }
            await mark("auto-start", "first-input")
            let point = try center(input)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 250_000_000)
            var typed = ""
            do {
                for (index, character) in "Modore QA test".enumerated() {
                    try verify(target, element: input)
                    guard value(input) == typed,
                          let focused = attribute(AXUIElementCreateApplication(target.pid), kAXFocusedUIElementAttribute as CFString),
                          CFEqual(focused, input) else { throw ReplayError.changed }
                    if index == 1 { await mark("auto-start", "continued-input") }
                    let units = Array(String(character).utf16)
                    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                          let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw ReplayError.unavailable }
                    down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    down.postToPid(target.pid); up.postToPid(target.pid)
                    typed += String(character)
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard value(input) == typed else { throw ReplayError.changed }
                await mark("auto-verified", "시험 문자열의 접근성 값 확인 · 화면 지연 미측정")
                try verify(target, element: hover)
                await mark("auto-start", "sidebar-hover")
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: try center(hover), mouseButton: .left)?.post(tap: .cghidEventTap)
                try await Task.sleep(nanoseconds: 800_000_000)
                try verify(target, element: input)
                guard value(input) == typed,
                      AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, "" as CFString) == .success,
                      value(input) == "" else { throw ReplayError.cleanup }
                await mark("auto-finished", "시험 입력 제거 확인")
                try await Task.sleep(nanoseconds: 800_000_000)
            } catch {
                // Never overwrite an intervening user edit or send keyboard shortcuts to an unknown responder.
                if !typed.isEmpty, value(input) == typed {
                    _ = AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, "" as CFString)
                }
                throw error
            }
        }
        message = "자동 재현 종료 · 화면 끊김 여부는 별도 확인이 필요합니다."
    }
    private func installEscape() {
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.onStop?() }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.onStop?() }
            return event
        }
    }
    private func removeEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        escapeMonitor = nil; localEscapeMonitor = nil
    }
    enum ReplayError: LocalizedError {
        case unavailable, changed, cleanup
        var errorDescription: String? {
            switch self {
            case .unavailable: return "등록한 빈 입력창·목록 위치 또는 접근성 권한을 확인하세요."
            case .changed: return "대상·포커스·입력 내용이 바뀌어 자동 조작을 중단했습니다."
            case .cleanup: return "시험 입력 제거를 확인하지 못했습니다. 입력창을 확인하세요."
            }
        }
    }
}
