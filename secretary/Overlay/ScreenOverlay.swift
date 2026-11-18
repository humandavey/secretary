//
//  ScreenOverlay.swift
//  secretary
//

import AppKit

/// A click-through window that covers one screen and holds the ink drawn over it.
@MainActor
final class ScreenOverlayController {
    private let canvas = InkCanvas(style: .screen)
    private var panel: NSPanel?
    private var screen: NSScreen?

    /// What is drawn over the screen right now.
    var items: [InkAction] { canvas.items }

    /// The canvas covering `screen`, with its window showing.
    func canvas(on screen: NSScreen) -> InkCanvas {
        if let current = self.screen, current != screen {
            // Ink is placed in fractions of one display, so it means nothing on another.
            canvas.removeAll()
        }
        self.screen = screen
        let panel = self.panel ?? makePanel(on: screen)
        self.panel = panel
        if panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: true)
        }
        panel.orderFrontRegardless()
        return canvas
    }

    /// Puts back ink that was already drawn, or hides the window when there is none.
    func show(_ items: [InkAction], on screen: NSScreen) {
        guard !items.isEmpty else {
            clear()
            return
        }
        canvas(on: screen).show(items)
    }

    func finishAnimations() {
        canvas.finishAnimations()
    }

    func clear() {
        canvas.removeAll()
        panel?.orderOut(nil)
    }

    private func makePanel(on screen: NSScreen) -> NSPanel {
        let panel = OverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.canHide = false
        panel.contentView = canvas
        return panel
    }
}

private final class OverlayPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
