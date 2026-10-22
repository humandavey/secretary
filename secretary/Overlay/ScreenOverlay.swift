//
//  ScreenOverlay.swift
//  secretary
//

import AppKit
import AVFoundation
import QuartzCore

@MainActor
final class SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()
    private let settings: SpeechSettings

    init(settings: SpeechSettings) {
        self.settings = settings
    }

    func speak(_ text: String, force: Bool = false) {
        stop()
        enqueue(text, force: force)
    }

    func enqueue(_ text: String, force: Bool = false) {
        guard force || settings.speaksAnswers else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = settings.voice
        utterance.rate = settings.utteranceRate
        utterance.pitchMultiplier = settings.pitchMultiplier
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

@MainActor
final class ScreenOverlayController {
    private let voice: SpeechOutput
    private var annotationWindow: NSWindow?
    private var storedExplanation: ScreenExplanation?
    private var storedScreen: NSScreen?
    private var drawingsVisible = false

    init(settings: SpeechSettings) {
        voice = SpeechOutput(settings: settings)
    }

    func setDrawingsVisible(_ visible: Bool) {
        drawingsVisible = visible
        guard visible, let storedExplanation, let storedScreen, !storedExplanation.annotations.isEmpty else {
            annotationWindow?.orderOut(nil)
            return
        }
        installOverlay(storedExplanation, on: storedScreen)
    }

    func present(explanation: ScreenExplanation, on screen: NSScreen, speaks: Bool = true) {
        storedExplanation = explanation
        storedScreen = screen
        if drawingsVisible, !explanation.annotations.isEmpty {
            installOverlay(explanation, on: screen)
        } else {
            annotationWindow?.orderOut(nil)
        }
        if speaks {
            speak(explanation.speech)
        }
    }

    func speak(_ text: String, force: Bool = false) {
        voice.speak(text, force: force)
    }

    func stopSpeaking() {
        voice.stop()
    }

    func enqueue(_ text: String) {
        voice.enqueue(text)
    }

    func dismiss() {
        voice.stop()
        storedExplanation = nil
        storedScreen = nil
        removeAnnotations()
    }

    private func installOverlay(_ explanation: ScreenExplanation, on screen: NSScreen) {
        let window = annotationWindow ?? makeAnnotationWindow(on: screen)
        window.setFrame(screen.frame, display: false)
        let size = window.contentRect(forFrameRect: window.frame).size
        let view = (window.contentView as? OverlayDrawingView) ?? OverlayDrawingView(frame: NSRect(origin: .zero, size: size))
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        view.screen = screen
        view.marks = explanation.annotations
        window.contentView = view
        window.alphaValue = 1
        window.orderFrontRegardless()
        window.setFrame(screen.frame, display: true)
        view.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        view.rebuild()
        annotationWindow = window
    }

    private func removeAnnotations() {
        annotationWindow?.orderOut(nil)
        annotationWindow = nil
    }

    private func makeAnnotationWindow(on screen: NSScreen) -> NSWindow {
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
        return panel
    }
}

private final class OverlayPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class OverlayDrawingView: NSView {
    var screen: NSScreen?
    var marks: [ScreenMark] = [] {
        didSet { rebuild() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        rebuild()
    }

    fileprivate func rebuild() {
        guard let layer else { return }
        layer.sublayers = nil
        layer.backgroundColor = NSColor.clear.cgColor
        layer.isOpaque = false
        guard bounds.width > 2, bounds.height > 2 else { return }
        for mark in marks {
            guard let path = path(for: mark) else { continue }
            layer.addSublayer(stroke(path, color: NSColor.black.withAlphaComponent(0.75), width: 8))
            layer.addSublayer(stroke(path, color: NSColor(srgbRed: 1, green: 0.62, blue: 0.12, alpha: 1), width: 3.5))
        }
    }

    private func stroke(_ path: CGPath, color: NSColor, width: CGFloat) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.bounds = layer?.bounds ?? .zero
        shape.anchorPoint = .zero
        shape.position = .zero
        shape.path = path
        shape.fillColor = nil
        shape.strokeColor = color.cgColor
        shape.lineWidth = width
        shape.lineCap = .round
        shape.lineJoin = .round
        return shape
    }

    private func path(for mark: ScreenMark) -> CGPath? {
        switch mark.shape {
        case "arrow":
            let tail = layerPoint(mark.x, mark.y)
            let head = layerPoint(mark.width, mark.height)
            let path = CGMutablePath()
            path.move(to: tail)
            path.addLine(to: head)
            let angle = atan2(head.y - tail.y, head.x - tail.x)
            let length: CGFloat = 18
            let spread: CGFloat = .pi / 7
            path.move(to: CGPoint(x: head.x - length * cos(angle - spread), y: head.y - length * sin(angle - spread)))
            path.addLine(to: head)
            path.addLine(to: CGPoint(x: head.x - length * cos(angle + spread), y: head.y - length * sin(angle + spread)))
            return path
        case "rectangle":
            return CGPath(roundedRect: box(for: mark), cornerWidth: 6, cornerHeight: 6, transform: nil)
        default:
            return CGPath(ellipseIn: box(for: mark), transform: nil)
        }
    }

    /// Mark x/y are the top-left of the screen. The view's origin is the bottom-left.
    private func box(for mark: ScreenMark) -> CGRect {
        aligned(viewRect(x: mark.x, y: mark.y, width: mark.width, height: mark.height))
    }

    private func layerPoint(_ x: Double, _ y: Double) -> CGPoint {
        let x = min(1, max(0, x))
        let y = min(1, max(0, y))
        guard let screen, let window else {
            return CGPoint(x: CGFloat(x) * bounds.width, y: bounds.height - CGFloat(y) * bounds.height)
        }
        let frame = screen.frame
        let screenPoint = NSPoint(
            x: frame.minX + CGFloat(x) * frame.width,
            y: frame.maxY - CGFloat(y) * frame.height
        )
        return convert(window.convertPoint(fromScreen: screenPoint), from: nil)
    }

    private func viewRect(x: Double, y: Double, width: Double, height: Double) -> CGRect {
        let x = min(1, max(0, x))
        let y = min(1, max(0, y))
        let width = min(1, max(0, width))
        let height = min(1, max(0, height))
        guard let screen, let window else {
            return CGRect(
                x: CGFloat(x) * bounds.width,
                y: bounds.height - CGFloat(y + height) * bounds.height,
                width: CGFloat(width) * bounds.width,
                height: CGFloat(height) * bounds.height
            )
        }
        let frame = screen.frame
        let screenRect = CGRect(
            x: frame.minX + CGFloat(x) * frame.width,
            y: frame.maxY - CGFloat(y + height) * frame.height,
            width: CGFloat(width) * frame.width,
            height: CGFloat(height) * frame.height
        )
        return convert(window.convertFromScreen(screenRect), from: nil)
    }

    private func aligned(_ rect: CGRect) -> CGRect {
        let scale = window?.backingScaleFactor ?? 2
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return CGRect(x: snap(rect.minX), y: snap(rect.minY), width: max(1 / scale, snap(rect.width)), height: max(1 / scale, snap(rect.height)))
    }
}
