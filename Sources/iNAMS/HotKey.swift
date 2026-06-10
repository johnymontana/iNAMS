import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon's RegisterEventHotKey — works without the
/// Accessibility permission an NSEvent global monitor would need, and is
/// App Sandbox-safe should that ever matter.
@MainActor
final class HotKey {
    static let keyM = UInt32(kVK_ANSI_M)
    static let controlOption = UInt32(controlKey | optionKey)

    private static var nextID: UInt32 = 1
    private static var registry: [UInt32: HotKey] = [:]
    private static var eventHandlerInstalled = false

    private let id: UInt32
    private let handler: () -> Void
    private var hotKeyRef: EventHotKeyRef?

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.id = Self.nextID
        self.handler = handler
        Self.nextID += 1
        Self.installEventHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x494E_414D), id: id) // 'INAM'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        hotKeyRef = ref
        Self.registry[id] = self
    }

    func invalidate() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        Self.registry[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // The handler runs on the main event loop, so hopping straight into
        // MainActor state is sound.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            MainActor.assumeIsolated {
                HotKey.registry[hotKeyID.id]?.handler()
            }
            return noErr
        }, 1, &eventType, nil, nil)
        eventHandlerInstalled = true
    }
}
