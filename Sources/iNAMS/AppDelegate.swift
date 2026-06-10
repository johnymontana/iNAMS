import AppKit
import iNAMSKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState!
    private var statusItemController: StatusItemController!
    private var panelController: PanelController!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        appState = AppState()
        panelController = PanelController(appState: appState)
        statusItemController = StatusItemController(appState: appState, panelController: panelController)

        // ⌃⌥M — summon the capture palette from anywhere.
        hotKey = HotKey(keyCode: HotKey.keyM, modifiers: HotKey.controlOption) { [weak self] in
            self?.panelController.toggle(mode: .capture)
        }

        appState.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.stop()
    }
}
