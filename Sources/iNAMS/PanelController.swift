import AppKit
import SwiftUI
import iNAMSKit

enum PaletteMode {
    case capture
    case search
}

/// Spotlight-style floating panel: becomes key without activating the app,
/// floats above everything, hides on Esc or when it loses key status. This
/// is the part pure SwiftUI MenuBarExtra can't do (see docs/PLAN.md).
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private var panel: FloatingPanel?

    init(appState: AppState) {
        self.appState = appState
    }

    func toggle(mode: PaletteMode) {
        if let panel, panel.isVisible {
            hide()
        } else {
            show(mode: mode)
        }
    }

    func show(mode: PaletteMode) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        panel.contentView = NSHostingView(
            rootView: PaletteView(appState: appState, mode: mode) { [weak self] in
                self?.hide()
            }
        )

        // Upper third of the screen with the mouse, Spotlight-style.
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.minY + frame.height * 0.62
            ))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 360))
        panel.delegate = self
        return panel
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in self.hide() }
    }
}
