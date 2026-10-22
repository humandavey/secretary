//
//  WhiteboardController.swift
//  secretary
//

import AppKit
import WebKit

@MainActor
final class WhiteboardController: NSObject, WKNavigationDelegate, NSWindowDelegate {
    var onVisibilityChange: ((Bool) -> Void)?
    var speakLine: ((String, Bool, @escaping @MainActor () -> Void) -> Void)?
    var stopSpeech: (() -> Void)?

    private var panel: NSPanel?
    private var canvas: LessonCanvas?
    private var webView: WKWebView?
    private var storedHTML: String?
    private var storedTitle = ""
    private var storedScreen: NSScreen?

    private var intro = ""
    private var preamble = ""
    private var beats: [LessonBeat] = []
    private var index = 0
    private var speaks = false
    private var onTranscript: ((String) -> Void)?
    private var speechToken = UUID()

    var hasLesson: Bool { !beats.isEmpty }

    func isWindow(_ window: NSWindow?) -> Bool {
        guard let window, let panel else { return false }
        return window === panel
    }

    func present(html: String, title: String, on screen: NSScreen) {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        clearLesson()
        storedHTML = trimmed
        storedTitle = title
        storedScreen = screen
        show(title: title, on: screen)
        canvas?.showsBar = false
        load(trimmed)
    }

    func play(
        intro: String,
        preamble: String,
        beats: [LessonBeat],
        title: String,
        on screen: NSScreen,
        speaks: Bool,
        onTranscript: @escaping (String) -> Void
    ) {
        guard !beats.isEmpty else { return }
        speechToken = UUID()
        stopSpeech?()
        self.intro = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preamble = preamble
        self.beats = beats
        self.speaks = speaks
        self.onTranscript = onTranscript
        index = self.intro.isEmpty ? 0 : -1
        storedHTML = frameHTML()
        storedTitle = title
        storedScreen = screen
        show(title: title, on: screen)
        canvas?.showsBar = beats.count > 1 || !self.intro.isEmpty
        renderAndSpeak()
    }

    func replay() {
        guard hasLesson else { return }
        speaks = true
        speechToken = UUID()
        stopSpeech?()
        index = intro.isEmpty ? 0 : -1
        if panel == nil, let screen = storedScreen {
            show(title: storedTitle, on: screen)
        } else {
            panel?.orderFrontRegardless()
            onVisibilityChange?(true)
        }
        canvas?.showsBar = beats.count > 1 || !intro.isEmpty
        renderAndSpeak()
    }

    func showAgain() {
        guard let storedHTML else { return }
        guard let screen = storedScreen ?? NSScreen.main else { return }
        if panel == nil {
            if hasLesson {
                show(title: storedTitle, on: screen)
                canvas?.showsBar = beats.count > 1 || !intro.isEmpty
                load(frameHTML())
                publishTranscript()
            } else {
                present(html: storedHTML, title: storedTitle, on: screen)
            }
            return
        }
        panel?.orderFrontRegardless()
        onVisibilityChange?(true)
    }

    func dismiss() {
        clearLesson()
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

    @objc private func goBack() {
        let minimum = intro.isEmpty ? 0 : -1
        guard index > minimum else { return }
        speechToken = UUID()
        stopSpeech?()
        index -= 1
        renderAndSpeak()
    }

    @objc private func goForward() {
        guard index + 1 < beats.count else { return }
        speechToken = UUID()
        stopSpeech?()
        index += 1
        renderAndSpeak()
    }

    private func renderAndSpeak() {
        let html = frameHTML()
        storedHTML = html
        load(html)
        publishTranscript()
        updateControls()
        let line = currentLine
        guard speaks else { return }
        guard !line.isEmpty else {
            advanceFromSpeech()
            return
        }
        let token = UUID()
        speechToken = token
        speakLine?(line, true) { [weak self] in
            guard let self, self.speechToken == token else { return }
            self.advanceFromSpeech()
        }
    }

    private func advanceFromSpeech() {
        guard index + 1 < beats.count else { return }
        index += 1
        renderAndSpeak()
    }

    private func publishTranscript() {
        var lines: [String] = []
        if !intro.isEmpty { lines.append(intro) }
        if index >= 0 {
            lines.append(contentsOf: beats.prefix(index + 1).map(\.say).filter { !$0.isEmpty })
        }
        onTranscript?(lines.joined(separator: " "))
    }

    private var currentLine: String {
        if index < 0 { return intro }
        guard beats.indices.contains(index) else { return "" }
        return beats[index].say
    }

    private func frameHTML() -> String {
        var parts: [String] = []
        if !preamble.isEmpty { parts.append(preamble) }
        guard index >= 0 else { return parts.joined(separator: "\n") }
        for beat in beats.prefix(index) {
            parts.append("<div class=\"settled\">\(beat.html)</div>")
        }
        if beats.indices.contains(index) {
            parts.append(beats[index].html)
        }
        return parts.joined(separator: "\n")
    }

    private func updateControls() {
        guard let canvas else { return }
        let minimum = intro.isEmpty ? 0 : -1
        canvas.backButton.isEnabled = index > minimum
        canvas.nextButton.isEnabled = index + 1 < beats.count
        if index < 0 {
            canvas.stepLabel.stringValue = "Intro"
        } else {
            canvas.stepLabel.stringValue = "\(index + 1) of \(beats.count)"
        }
    }

    private func clearLesson() {
        speechToken = UUID()
        stopSpeech?()
        intro = ""
        preamble = ""
        beats = []
        index = 0
        speaks = false
        onTranscript = nil
        canvas?.showsBar = false
    }

    private func show(title: String, on screen: NSScreen) {
        let panel = ensurePanel(on: screen)
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.title = cleanedTitle.isEmpty ? "Whiteboard" : cleanedTitle
        panel.setFrame(frame(on: screen), display: true)
        panel.orderFrontRegardless()
        onVisibilityChange?(true)
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
        let canvas = LessonCanvas(webView: webView)
        canvas.backButton.target = self
        canvas.backButton.action = #selector(goBack)
        canvas.nextButton.target = self
        canvas.nextButton.action = #selector(goForward)
        panel.contentView = canvas
        self.webView = webView
        self.canvas = canvas
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
          .say { display: none !important; }
          .settled, .settled * { animation: none !important; transition: none !important; }
        </style>
        </head>
        <body><main>
        \(fragment)
        </main></body>
        </html>
        """
    }
}

private final class LessonCanvas: NSView {
    let backButton = NSButton(title: "Back", target: nil, action: nil)
    let nextButton = NSButton(title: "Next", target: nil, action: nil)
    let stepLabel = NSTextField(labelWithString: "")
    let bar = NSView()
    let webView: WKWebView
    var showsBar = false {
        didSet { position() }
    }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.957, green: 0.937, blue: 0.890, alpha: 1).cgColor
        autoresizesSubviews = false
        for button in [backButton, nextButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setButtonType(.momentaryPushIn)
        }
        stepLabel.font = .systemFont(ofSize: 12)
        stepLabel.textColor = .secondaryLabelColor
        stepLabel.alignment = .center
        bar.addSubview(backButton)
        bar.addSubview(stepLabel)
        bar.addSubview(nextButton)
        addSubview(bar)
        addSubview(webView)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        position()
    }

    private func position() {
        let barHeight: CGFloat = showsBar ? 40 : 0
        let barWidth = max(0, bounds.width - 32)
        bar.isHidden = !showsBar
        bar.frame = NSRect(x: 16, y: bounds.height - barHeight + 6, width: barWidth, height: 28)
        backButton.frame = NSRect(x: 0, y: 0, width: 72, height: 24)
        nextButton.frame = NSRect(x: max(0, barWidth - 72), y: 0, width: 72, height: 24)
        stepLabel.frame = NSRect(x: 80, y: 3, width: max(0, barWidth - 160), height: 18)
        webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barHeight))
    }
}
