//
//  BoardController.swift
//  secretary
//

import AppKit

/// The whiteboard: a floating window the lesson draws on when a picture helps.
@MainActor
final class BoardController: NSObject, NSWindowDelegate {
    /// Reports whether this conversation has opened the board, and whether its window is showing.
    var onChange: ((_ opened: Bool, _ visible: Bool) -> Void)?

    let canvas = InkCanvas(style: .board)
    private var panel: NSPanel?
    private(set) var isOpened = false

    func isWindow(_ window: NSWindow?) -> Bool {
        guard let window, let panel else { return false }
        return window === panel
    }

    func open(title: String, on screen: NSScreen) {
        let panel = self.panel ?? makePanel(on: screen)
        self.panel = panel
        panel.title = title.isEmpty ? "Whiteboard" : title
        isOpened = true
        panel.orderFrontRegardless()
        onChange?(true, true)
    }

    /// Brings back a board the person closed.
    func showAgain() {
        guard isOpened, let panel else { return }
        panel.orderFrontRegardless()
        onChange?(true, true)
    }

    /// Erases the board and closes it.
    func reset() {
        canvas.removeAll()
        isOpened = false
        panel?.orderOut(nil)
        onChange?(false, false)
    }

    func windowWillClose(_ notification: Notification) {
        onChange?(isOpened, false)
    }

    private func makePanel(on screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame(on: screen),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.minSize = NSSize(width: 420, height: 320)
        panel.delegate = self
        panel.contentView = canvas
        return panel
    }

    /// The right side of the screen, in the board's own shape.
    private func frame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = min(720, max(420, visible.width - 48))
        let height = min(width / InkCanvas.boardAspect, max(320, visible.height - 80))
        return NSRect(
            x: visible.maxX - width - 24,
            y: visible.minY + (visible.height - height) / 2,
            width: width,
            height: height
        )
    }
}
