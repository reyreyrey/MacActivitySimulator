import Cocoa
import Carbon.HIToolbox

/// 全局快捷键管理（基于 Carbon RegisterEventHotKey，系统级有效，无需窗口聚焦）
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var startKeyRef: EventHotKeyRef?
    private var stopKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    /// id → 回调
    private static var actions: [UInt32: () -> Void] = [:]

    private let startHotKeyID: UInt32 = 1
    private let stopHotKeyID: UInt32  = 2

    private init() {}

    /// 注册快捷键：⌥⌘S = 开始，⌥⌘X = 结束
    func setup(start: @escaping () -> Void, stop: @escaping () -> Void) {
        installHandlerIfNeeded()

        // ⌘ + ⌥
        let modifiers: UInt32 = UInt32(cmdKey | optionKey)

        // 注册 ⌥⌘S
        unregister(&startKeyRef)
        startKeyRef = register(keyCode: UInt32(kVK_ANSI_S), modifiers: modifiers, id: startHotKeyID)
        HotKeyManager.actions[startHotKeyID] = start

        // 注册 ⌥⌘X
        unregister(&stopKeyRef)
        stopKeyRef = register(keyCode: UInt32(kVK_ANSI_X), modifiers: modifiers, id: stopHotKeyID)
        HotKeyManager.actions[stopHotKeyID] = stop

        log("⌨️ 已注册全局快捷键：⌥⌘S 开始 / ⌥⌘X 结束")
    }

    func teardown() {
        unregister(&startKeyRef)
        unregister(&stopKeyRef)
        HotKeyManager.actions.removeAll()
    }

    // MARK: - 私有

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> EventHotKeyRef? {
        let signature: OSType = 0x4D414353 // 'MACS'
        let hkID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            log("⚠️ 快捷键注册失败 status=\(status) keyCode=\(keyCode)")
            return nil
        }
        return ref
    }

    private func unregister(_ ref: inout EventHotKeyRef?) {
        if let r = ref {
            UnregisterEventHotKey(r)
        }
        ref = nil
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(),
                            { (_, eventRef, _) -> OSStatus in
            guard let eventRef = eventRef else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(eventRef,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hkID)
            if status == noErr, let action = HotKeyManager.actions[hkID.id] {
                DispatchQueue.main.async { action() }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }, 1, &eventType, nil, nil)

        handlerInstalled = true
    }
}
