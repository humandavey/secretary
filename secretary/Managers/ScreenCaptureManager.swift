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
}
