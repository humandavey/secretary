//
//  InkCanvas.swift
//  secretary
//

import AppKit
import QuartzCore
import SwiftMath

/// Draws lesson ink, over the screen or on the whiteboard, and can draw each item in over time.
final class InkCanvas: NSView {
    enum Style {
        case screen
        case board
    }

    /// Width over height of the whiteboard's drawing area. The lesson prompt tells the model the same shape.
    static let boardAspect: CGFloat = 4.0 / 3.0

    private let style: Style
    private(set) var items: [InkAction] = []
    private var builtSize = CGSize.zero

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = (style == .board ? Palette.paper : NSColor.clear).cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { style == .board }

    override func layout() {
        super.layout()
        rebuildIfResized()
    }

    /// Adds one item and draws it in, starting after `delay`.
    func add(_ item: InkAction, over duration: TimeInterval, after delay: TimeInterval) {
        // A resize rebuilds every layer, which would cut this animation short if it happened later.
        rebuildIfResized()
        items.append(item)
        guard let layer, let ink = ink(for: item) else { return }
        layer.addSublayer(ink.layer)
        let start = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        for reveal in ink.reveals {
            reveal.run(from: start, over: duration)
        }
    }

    /// Replaces everything with `items`, already drawn.
    func show(_ items: [InkAction]) {
        self.items = items
        rebuild()
    }

    func removeAll() {
        show([])
    }

    /// Jumps every item to its finished state.
    func finishAnimations() {
        for sublayer in layer?.sublayers ?? [] {
            Self.settle(sublayer)
        }
    }

    private static func settle(_ layer: CALayer) {
        layer.removeAllAnimations()
        layer.mask = nil
        for sublayer in layer.sublayers ?? [] {
            settle(sublayer)
        }
    }

    private func rebuildIfResized() {
        guard bounds.size != builtSize else { return }
        rebuild()
    }

    private func rebuild() {
        builtSize = bounds.size
        guard let layer else { return }
        layer.sublayers = nil
        guard bounds.width > 2, bounds.height > 2 else { return }
        for item in items {
            if let ink = ink(for: item) {
                layer.addSublayer(ink.layer)
            }
        }
    }

    // MARK: Geometry

    /// Where fractions land. The screen uses the whole view. The board keeps its shape inside the window.
    private var area: CGRect {
        guard style == .board else { return bounds }
        let inset = bounds.insetBy(dx: 12, dy: 12)
        let width = min(inset.width, inset.height * Self.boardAspect)
        let height = width / Self.boardAspect
        return CGRect(x: inset.midX - width / 2, y: inset.midY - height / 2, width: width, height: height)
    }

    /// Fractions run down from the top-left. The view's origin is the bottom-left.
    private func point(_ fraction: CGPoint) -> CGPoint {
        let area = area
        return CGPoint(x: area.minX + fraction.x * area.width, y: area.maxY - fraction.y * area.height)
    }

    private func box(_ corners: [CGPoint]) -> CGRect {
        let a = point(corners[0])
        let b = point(corners[1])
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private var scale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    // MARK: Ink

    private struct Ink {
        let layer: CALayer
        var reveals: [Reveal] = []
    }

    /// How one layer comes in, as a slice of the time its item takes to draw.
    private struct Reveal {
        enum Kind {
            case draw
            case wipe
            case fade
        }

        let layer: CALayer
        let kind: Kind
        var slice: ClosedRange<Double> = 0...1

        func run(from start: CFTimeInterval, over duration: TimeInterval) {
            let animation: CABasicAnimation
            var target = layer
            switch kind {
            case .draw:
                animation = CABasicAnimation(keyPath: "strokeEnd")
                animation.fromValue = 0
                animation.toValue = 1
            case .fade:
                animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 0
                animation.toValue = 1
            case .wipe:
                // Uncovers the layer from left to right, the way writing appears.
                let mask = CALayer()
                mask.backgroundColor = NSColor.black.cgColor
                mask.anchorPoint = .zero
                mask.frame = layer.bounds
                layer.mask = mask
                animation = CABasicAnimation(keyPath: "bounds.size.width")
                animation.fromValue = 0
                animation.toValue = layer.bounds.width
                target = mask
            }
            animation.beginTime = start + duration * slice.lowerBound
            animation.duration = max(0.05, duration * (slice.upperBound - slice.lowerBound))
            animation.fillMode = .backwards
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            target.add(animation, forKey: "reveal")
        }
    }

    private func ink(for item: InkAction) -> Ink? {
        switch item.type {
        case .stroke, .arrow, .circle, .rectangle:
            return path(for: item).map(lineInk)
        case .text:
            guard let anchor = item.points.first else { return nil }
            return style == .screen ? labelInk(item.text, at: point(anchor)) : textInk(item.text, at: point(anchor))
        case .latex:
            return item.points.first.map { latexInk(item.text, at: point($0)) }
        case .plot:
            return plotInk(item)
        case .open, .clear:
            return nil
        }
    }

    private func path(for item: InkAction) -> CGPath? {
        guard item.points.count >= 2 else { return nil }
        switch item.type {
        case .circle:
            return CGPath(ellipseIn: box(item.points), transform: nil)
        case .rectangle:
            let rect = box(item.points)
            let corner = min(4, rect.width / 2, rect.height / 2)
            return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        default:
            let points = item.points.map(point)
            let path = CGMutablePath()
            path.addLines(between: points)
            if item.type == .arrow, let head = points.last,
               let before = points.dropLast().last(where: { hypot($0.x - head.x, $0.y - head.y) > 1 }) {
                let angle = atan2(head.y - before.y, head.x - before.x)
                let length = style == .screen ? 18 : max(10, area.height * 0.03)
                let spread = CGFloat.pi / 7
                path.move(to: CGPoint(x: head.x - length * cos(angle - spread), y: head.y - length * sin(angle - spread)))
                path.addLine(to: head)
                path.addLine(to: CGPoint(x: head.x - length * cos(angle + spread), y: head.y - length * sin(angle + spread)))
            }
            return path
        }
    }

    private func lineInk(_ path: CGPath) -> Ink {
        // Screen ink gets a dark edge so it reads on any background.
        let lines: [(NSColor, CGFloat)] = style == .screen
            ? [(NSColor.black.withAlphaComponent(0.75), 8), (Palette.screenInk, 3.5)]
            : [(Palette.ink, max(2, area.height * 0.006))]
        let container = CALayer()
        container.frame = bounds
        var reveals: [Reveal] = []
        for (color, width) in lines {
            let shape = shapeLayer(path, color: color, width: width)
            shape.frame = container.bounds
            container.addSublayer(shape)
            reveals.append(Reveal(layer: shape, kind: .draw))
        }
        return Ink(layer: container, reveals: reveals)
    }

    private func shapeLayer(_ path: CGPath, color: NSColor, width: CGFloat) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.path = path
        shape.fillColor = nil
        shape.strokeColor = color.cgColor
        shape.lineWidth = width
        shape.lineCap = .round
        shape.lineJoin = .round
        return shape
    }

    private func textLayer(_ string: String, font: NSFont, color: NSColor, maxWidth: CGFloat) -> CATextLayer {
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let fitted = text.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let layer = CATextLayer()
        layer.string = text
        layer.isWrapped = true
        layer.contentsScale = scale
        layer.bounds = CGRect(x: 0, y: 0, width: ceil(fitted.width), height: ceil(fitted.height))
        layer.anchorPoint = .zero
        return layer
    }

    /// Board writing, with its top-left corner at `anchor`.
    private func textInk(_ string: String, at anchor: CGPoint) -> Ink {
        let font = NSFont.systemFont(ofSize: area.height * 0.05, weight: .medium)
        let layer = textLayer(string, font: font, color: Palette.ink, maxWidth: max(60, area.maxX - anchor.x))
        layer.position = CGPoint(x: anchor.x, y: anchor.y - layer.bounds.height)
        return Ink(layer: layer, reveals: [Reveal(layer: layer, kind: .wipe)])
    }

    /// A short label over the screen, on a dark tag so it reads on any background.
    private func labelInk(_ string: String, at anchor: CGPoint) -> Ink {
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let text = textLayer(string, font: font, color: .white, maxWidth: 320)
        let size = CGSize(width: text.bounds.width + 16, height: text.bounds.height + 8)
        let tag = CALayer()
        tag.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        tag.borderColor = Palette.screenInk.cgColor
        tag.borderWidth = 1.5
        tag.cornerRadius = 6
        tag.frame = CGRect(
            x: min(max(0, anchor.x), max(0, bounds.width - size.width)),
            y: min(max(0, anchor.y - size.height), max(0, bounds.height - size.height)),
            width: size.width,
            height: size.height
        )
        text.position = CGPoint(x: 8, y: 4)
        tag.addSublayer(text)
        return Ink(layer: tag, reveals: [Reveal(layer: tag, kind: .fade)])
    }

    private func latexInk(_ source: String, at anchor: CGPoint) -> Ink {
        func typeset(at fontSize: CGFloat) -> NSImage? {
            var math = MathImage(latex: source, fontSize: fontSize, textColor: Palette.ink, labelMode: .display, textAlignment: .left)
            return math.asImage().1
        }
        let fontSize = area.height * 0.055
        // SwiftMath covers most of LaTeX math, not all of it. The source is still worth showing when it can't be set.
        guard var image = typeset(at: fontSize) else { return textInk(source, at: anchor) }
        // An equation cannot wrap, so one that would run off the board is set smaller.
        let room = max(60, area.maxX - anchor.x)
        if image.size.width > room, let smaller = typeset(at: fontSize * room / image.size.width) {
            image = smaller
        }
        let layer = CALayer()
        var rect = NSRect(origin: .zero, size: image.size)
        layer.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) ?? image
        layer.contentsScale = scale
        layer.contentsGravity = .resizeAspect
        layer.frame = CGRect(x: anchor.x, y: anchor.y - image.size.height, width: image.size.width, height: image.size.height)
        return Ink(layer: layer, reveals: [Reveal(layer: layer, kind: .wipe)])
    }

    private func plotInk(_ item: InkAction) -> Ink? {
        guard item.points.count >= 2,
              let curve = PlotCurve(expression: item.text, domain: item.domain, data: item.data) else { return nil }
        let frame = box(item.points)
        guard frame.width > 24, frame.height > 24 else { return nil }

        func place(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(
                x: (x - curve.x.lowerBound) / (curve.x.upperBound - curve.x.lowerBound) * frame.width,
                y: (y - curve.y.lowerBound) / (curve.y.upperBound - curve.y.lowerBound) * frame.height
            )
        }

        // Axes cross at zero when zero is in view, and sit on the nearest edge when it is not.
        let origin = place(
            min(max(0, curve.x.lowerBound), curve.x.upperBound),
            min(max(0, curve.y.lowerBound), curve.y.upperBound)
        )
        let axesPath = CGMutablePath()
        axesPath.move(to: CGPoint(x: 0, y: origin.y))
        axesPath.addLine(to: CGPoint(x: frame.width, y: origin.y))
        axesPath.move(to: CGPoint(x: origin.x, y: 0))
        axesPath.addLine(to: CGPoint(x: origin.x, y: frame.height))
        let axes = shapeLayer(axesPath, color: Palette.ink.withAlphaComponent(0.55), width: 1.5)
        axes.frame = CGRect(origin: .zero, size: frame.size)

        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, area.height * 0.028), weight: .regular)
        func label(_ value: Double) -> CATextLayer {
            textLayer(String(format: "%.3g", value), font: font, color: Palette.ink.withAlphaComponent(0.7), maxWidth: 120)
        }
        let low = label(curve.x.lowerBound)
        let high = label(curve.x.upperBound)
        let top = label(curve.y.upperBound)
        let bottom = label(curve.y.lowerBound)
        let rowHeight = low.bounds.height
        // Numbers sit under the x-axis, or above it when the axis is on the bottom edge.
        let row = origin.y >= rowHeight + 2 ? origin.y - rowHeight - 2 : origin.y + 2
        // And to the right of the y-axis, or to its left when the axis is on the right edge.
        func beside(_ label: CATextLayer) -> CGFloat {
            origin.x + label.bounds.width + 6 <= frame.width ? origin.x + 4 : origin.x - label.bounds.width - 4
        }
        low.position = CGPoint(x: 0, y: row)
        high.position = CGPoint(x: frame.width - high.bounds.width, y: row)
        top.position = CGPoint(x: beside(top), y: frame.height - top.bounds.height)
        bottom.position = CGPoint(x: beside(bottom), y: 0)
        // With the x-axis on the bottom edge, the bottom number would land on the x numbers.
        let labels = origin.y > rowHeight * 2 ? [low, high, top, bottom] : [low, high, top]

        let curvePath = CGMutablePath()
        for segment in curve.segments {
            curvePath.addLines(between: segment.map { place(Double($0.x), Double($0.y)) })
        }
        let line = shapeLayer(curvePath, color: Palette.accent, width: max(2, area.height * 0.007))
        line.frame = CGRect(origin: .zero, size: frame.size)
        // A curve that runs off to infinity is cut at the edge of the graph.
        let clip = CALayer()
        clip.frame = line.frame
        clip.masksToBounds = true
        clip.addSublayer(line)

        let frameLayer = CALayer()
        frameLayer.frame = CGRect(origin: .zero, size: frame.size)
        frameLayer.addSublayer(axes)
        labels.forEach(frameLayer.addSublayer)

        let container = CALayer()
        container.frame = frame
        container.addSublayer(frameLayer)
        container.addSublayer(clip)
        return Ink(layer: container, reveals: [
            Reveal(layer: frameLayer, kind: .fade, slice: 0...0.3),
            Reveal(layer: line, kind: .draw, slice: 0.2...1)
        ])
    }
}

private enum Palette {
    static let paper = NSColor(srgbRed: 0.957, green: 0.937, blue: 0.890, alpha: 1)
    static let ink = NSColor(srgbRed: 0.114, green: 0.102, blue: 0.086, alpha: 1)
    static let accent = NSColor(srgbRed: 0.12, green: 0.37, blue: 0.75, alpha: 1)
    static let screenInk = NSColor(srgbRed: 1, green: 0.62, blue: 0.12, alpha: 1)
}
