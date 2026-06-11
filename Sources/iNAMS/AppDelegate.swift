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

        // `swift run` users have no other feedback that launch succeeded -
        // the icon can hide under the notch/overflow on a crowded menu bar.
        print("iNAMS is running. Look for the brain icon near the clock (a crowded menu bar or the notch can hide it).")
        print("Global hotkey: ctrl+opt+M toggles the capture panel even when the icon is hidden. Ctrl+C here quits.")
        print("API base: \(appState.config.apiBase) | connected: \(appState.isSignedIn)")
        fflush(stdout) // stdout is fully buffered when redirected to a file/pipe

        // First-run onboarding: a menu bar accessory has no window and the
        // icon can hide under the notch, so an unprompted first launch looks
        // like nothing happened. One-shot - cancelling is remembered and the
        // "Connect to NAMS…" menu item remains the way back in.
        let promptFlag = "HasOfferedConnectPrompt"
        if !appState.isSignedIn && !UserDefaults.standard.bool(forKey: promptFlag) {
            UserDefaults.standard.set(true, forKey: promptFlag)
            statusItemController.promptForKey()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.stop()
    }
}
