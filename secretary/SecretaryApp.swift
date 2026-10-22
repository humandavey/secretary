//
//  SecretaryApp.swift
//  secretary
//

import AppKit
import Combine
import SwiftUI

@main
struct SecretaryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = SecretarySession()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    override init() {
        super.init()
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let hosting = NSHostingController(rootView: ContentView(session: session))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover)
            // Mouse down toggles once. Mouse up was reopening the menu after the outside-click monitor had already closed it.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        statusItem = item
        updateIcon()

        session.$phase
            .sink { [weak self] phase in
                if phase == .presenting || phase == .failed {
                    self?.showPopover()
                }
            }
            .store(in: &cancellables)
        session.hideInterface = { [weak self] in
            self?.closePopover()
        }
        session.showInterface = { [weak self] in
            self?.showPopover()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            watchOutsideClicks()
        }
        resizePopover()
        session.setDrawingsVisible(true)
    }

    private func closePopover() {
        guard popover.isShown else {
            stopWatchingOutsideClicks()
            return
        }
        stopWatchingOutsideClicks()
        popover.close()
    }

    private func watchOutsideClicks() {
        let outside: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: outside) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.clickIsOnStatusButton() else { return }
                    self.closePopover()
                }
            }
        }
        if localClickMonitor == nil {
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: outside) { [weak self] event in
                guard let self else { return event }
                if self.clickStaysOpen(event) || self.clickIsOnStatusButton() { return event }
                Task { @MainActor in
                    guard !self.clickIsOnStatusButton() else { return }
                    self.closePopover()
                }
                return event
            }
        }
    }

    private func stopWatchingOutsideClicks() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }

    private func clickStaysOpen(_ event: NSEvent) -> Bool {
        if let window = popover.contentViewController?.view.window, event.window == window {
            return true
        }
        if event.window?.level == .popUpMenu {
            return true
        }
        return false
    }

    private func clickIsOnStatusButton() -> Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return rect.contains(NSEvent.mouseLocation)
    }

    private func resizePopover() {
        guard let hosting = popover.contentViewController else { return }
        hosting.view.layoutSubtreeIfNeeded()
        let height = min(640, max(280, hosting.view.fittingSize.height))
        popover.contentSize = NSSize(width: 320, height: height)
    }

    private func updateIcon() {
        let image = NSImage(systemSymbolName: "person.fill", accessibilityDescription: "Secretary")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        stopWatchingOutsideClicks()
        session.setDrawingsVisible(false)
    }
}
