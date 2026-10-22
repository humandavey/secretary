//
//  ScreenCaptureManager.swift
//  secretary
//

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct CapturedScreen {
    let image: CGImage
    let screen: NSScreen
    /// Area of `screen` covered by `image`, in points, with the origin at the top-left of the screen.
    let region: CGRect
    let focusName: String
}

enum ScreenCaptureError: LocalizedError {
    case permission
    case noDisplay
    case emptyImage

    var errorDescription: String? {
        switch self {
        case .permission:
            "Secretary needs Screen Recording permission. Allow it, quit Secretary, and open it again."
        case .noDisplay:
            "Secretary couldn't find the screen under your pointer."
        case .emptyImage:
            "The screenshot came back empty."
        }
    }
}

@MainActor
final class ScreenCaptureManager {
    func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    func capture() async throws -> CapturedScreen {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCaptureError.permission }
        guard let screen = screenUnderPointer() else { throw ScreenCaptureError.noDisplay }
        guard let displayID = screen.displayID else { throw ScreenCaptureError.noDisplay }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw ScreenCaptureError.noDisplay
        }

        let bundleID = Bundle.main.bundleIdentifier
        let excluded = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
        let image = try await screenshot(SCContentFilter(display: display, excludingWindows: excluded))
        return CapturedScreen(
            image: image,
            screen: screen,
            region: CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height),
            focusName: "this screen"
        )
    }

    private func screenshot(_ filter: SCContentFilter) async throws -> CGImage {
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = true
        configuration.ignoreShadows = true
        configuration.dynamicRange = .sdr
        configuration.displayIntent = .local
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
        guard let image = output.sdrImage else { throw ScreenCaptureError.emptyImage }
        return image
    }

}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}

extension CGImage {
    func fitted(maxEdge: CGFloat) -> CGImage {
        let longest = CGFloat(max(width, height))
        guard longest > maxEdge, maxEdge > 1 else { return self }

        let scale = maxEdge / longest
        let newWidth = max(1, Int((CGFloat(width) * scale).rounded()))
        let newHeight = max(1, Int((CGFloat(height) * scale).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return self }

        context.interpolationQuality = .medium
        context.draw(self, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? self
    }

    func jpegData(maxEdge: CGFloat, quality: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: fitted(maxEdge: maxEdge))
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Magenta rulers at every 100 units, drawn on the copy sent to the model.
    func withMeasurementGrid() -> CGImage {
        let pixelWidth = width
        let pixelHeight = height
        guard pixelWidth > 40, pixelHeight > 40 else { return self }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return self }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        let canvas = NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        NSImage(cgImage: self, size: canvas.size).draw(in: canvas)

        let lineColor = NSColor(srgbRed: 1, green: 0.08, blue: 0.7, alpha: 0.9)
        let fontSize = max(13, CGFloat(pixelWidth) / 72)
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -4
        ]
        let lineWidth = max(1, CGFloat(pixelWidth) / 900)

        for step in stride(from: 0, through: 1000, by: 100) {
            let fraction = CGFloat(step) / 1000
            let x = (fraction * CGFloat(pixelWidth)).rounded()
            let y = (CGFloat(pixelHeight) - fraction * CGFloat(pixelHeight)).rounded()
            lineColor.setStroke()

            let vertical = NSBezierPath()
            vertical.move(to: NSPoint(x: x, y: 0))
            vertical.line(to: NSPoint(x: x, y: CGFloat(pixelHeight)))
            vertical.lineWidth = lineWidth
            vertical.stroke()

            let horizontal = NSBezierPath()
            horizontal.move(to: NSPoint(x: 0, y: y))
            horizontal.line(to: NSPoint(x: CGFloat(pixelWidth), y: y))
            horizontal.lineWidth = lineWidth
            horizontal.stroke()

            let text = "\(step)" as NSString
            let labelSize = text.size(withAttributes: labelAttributes)
            let topLabelX = min(max(0, x + 3), CGFloat(pixelWidth) - labelSize.width)
            text.draw(
                at: NSPoint(x: topLabelX, y: CGFloat(pixelHeight) - labelSize.height - 2),
                withAttributes: labelAttributes
            )
            if step > 0 {
                let sideLabelY = min(max(0, y - labelSize.height - 2), CGFloat(pixelHeight) - labelSize.height)
                text.draw(at: NSPoint(x: 3, y: sideLabelY), withAttributes: labelAttributes)
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage ?? self
    }
}
