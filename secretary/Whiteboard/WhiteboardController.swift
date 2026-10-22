//
//  WhiteboardController.swift
//  secretary
//

import AppKit
import WebKit

@MainActor
final class WhiteboardController: NSObject, WKNavigationDelegate, NSWindowDelegate {
    var onVisibilityChange: ((Bool) -> Void)?

    private var panel: NSPanel?
    private var webView: WKWebView?
    private var storedHTML: String?
    private var storedTitle = ""
    private var storedScreen: NSScreen?

    func isWindow(_ window: NSWindow?) -> Bool {
        guard let window, let panel else { return false }
        return window === panel
    }

    func present(html: String, title: String, on screen: NSScreen) {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        storedHTML = trimmed
        storedTitle = title
        storedScreen = screen

        let panel = ensurePanel(on: screen)
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.title = cleanedTitle.isEmpty ? "Whiteboard" : cleanedTitle
        panel.setFrame(frame(on: screen), display: true)
        load(trimmed)
        panel.orderFrontRegardless()
        onVisibilityChange?(true)
    }

    func showAgain() {
        guard let storedHTML else { return }
        guard let screen = storedScreen ?? NSScreen.main else { return }
        if panel == nil {
            present(html: storedHTML, title: storedTitle, on: screen)
            return
        }
        panel?.orderFrontRegardless()
        onVisibilityChange?(true)
    }

    func dismiss() {
        storedHTML = nil
        storedTitle = ""
        storedScreen = nil
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange?(false)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .other {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            // loadHTMLString arrives as about:blank, or applewebdata when WebKit supplies its own base.
            if scheme == nil || scheme == "about" || scheme == "applewebdata" {
                decisionHandler(.allow)
                return
            }
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    private func ensurePanel(on screen: NSScreen) -> NSPanel {
        if let panel { return panel }
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
        panel.title = "Whiteboard"
        panel.delegate = self
        let webView = makeWebView()
        panel.contentView = webView
        self.webView = webView
        self.panel = panel
        return panel
    }

    private func makeWebView() -> WKWebView {
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences = preferences
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.allowsLinkPreview = false
        view.underPageBackgroundColor = boardColor
        return view
    }

    private func load(_ html: String) {
        webView?.loadHTMLString(wrapped(html), baseURL: nil)
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = min(640, max(420, visible.width - 48))
        let height = min(820, max(320, visible.height - 80))
        return NSRect(
            x: visible.maxX - width - 24,
            y: visible.minY + (visible.height - height) / 2,
            width: width,
            height: height
        )
    }

    private var boardColor: NSColor {
        NSColor(srgbRed: 0.957, green: 0.937, blue: 0.890, alpha: 1)
    }

    private func wrapped(_ fragment: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          :root { color-scheme: light; }
          html, body { margin: 0; background: #f4efe3; color: #1d1a16; }
          body { font: 17px/1.45 -apple-system, BlinkMacSystemFont, sans-serif; }
          main { padding: 28px 32px 48px; }
          h1 { font-size: 28px; line-height: 1.2; font-weight: 650; margin: 0 0 14px; }
          h2 { font-size: 20px; line-height: 1.25; margin: 22px 0 8px; }
          p { margin: 0 0 12px; }
          ul, ol { margin: 0 0 14px; padding-left: 1.25em; }
          li { margin: 0 0 4px; }
          svg { width: 100%; height: auto; display: block; margin: 8px 0 16px; }
          code { font-family: ui-monospace, SF Mono, Menlo, monospace; font-size: 0.92em; }
        </style>
        </head>
        <body><main>
        \(fragment)
        </main></body>
        </html>
        """
    }
}
