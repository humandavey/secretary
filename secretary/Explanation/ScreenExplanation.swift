//
//  ScreenExplanation.swift
//  secretary
//

import CoreGraphics
import Foundation
import FoundationModels

nonisolated struct ScreenMark {
    var shape: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var label: String

    func drawable() -> ScreenMark? {
        let kind: String
        switch shape.lowercased() {
        case "circle", "dot", "point", "ring", "ellipse":
            kind = "circle"
        case "rectangle", "rect", "box", "highlight", "region":
            kind = "rectangle"
        case "arrow", "line", "pointer":
            kind = "arrow"
        default:
            return nil
        }

        switch kind {
        case "circle":
            guard max(width, height) > 0.004 else { return nil }
        case "rectangle":
            guard width > 0.004, height > 0.004 else { return nil }
        default:
            let dx = width - x
            let dy = height - y
            guard (dx * dx) + (dy * dy) > 0.0003 else { return nil }
        }

        var mark = self
        mark.shape = kind
        return mark
    }

    /// Accepts 0...1 fractions or the model's 0...1000 units.
    func asFraction() -> ScreenMark {
        let maxValue = [x, y, width, height].map { abs($0) }.max() ?? 0
        let divisor: Double = maxValue <= 1.5 ? 1 : 1000
        var copy = self
        copy.x = min(1, max(0, x / divisor))
        copy.y = min(1, max(0, y / divisor))
        copy.width = min(1, max(0, width / divisor))
        copy.height = min(1, max(0, height / divisor))
        return copy
    }
}

@Generable(description: "An answer about a full Mac screenshot, plus marks the assistant chose to draw.")
nonisolated struct GeneratedExplanation {
    @Guide(description: "A short title, six words or fewer.")
    var title: String

    @Guide(description: "Two or three spoken sentences about the screen. Mention colors and objects when they answer the question. Never include coordinates.")
    var speech: String

    @Guide(description: "Marks you choose to draw on the screenshot. Empty when no drawing is needed.", .maximumCount(5))
    var annotations: [GeneratedMark]
}

@Generable(description: "One mark on the full screenshot. Edges are read from the measuring grid.")
nonisolated struct GeneratedMark {
    @Guide(description: "circle, rectangle, or arrow.", .anyOf(["circle", "rectangle", "arrow"]))
    var shape: String

    @Guide(description: "Grid number at the object's leftmost pixel. Smaller than the object's horizontal middle. 0 is the left edge and 1000 is the right edge. For an arrow, the tail.", .range(0...1000))
    var left: Int

    @Guide(description: "Grid number at the object's topmost pixel. 0 is the top edge and 1000 is the bottom edge. For an arrow, the tail.", .range(0...1000))
    var top: Int

    @Guide(description: "Grid number at the object's rightmost pixel. Greater than left. For an arrow, where the head lands horizontally.", .range(0...1000))
    var right: Int

    @Guide(description: "Grid number at the object's bottommost pixel. Greater than top. For an arrow, where the head lands vertically.", .range(0...1000))
    var bottom: Int

    @Guide(description: "Two or three words, or an empty string.")
    var label: String
}

nonisolated struct ScreenExplanation {
    var title: String
    var speech: String
    var annotations: [ScreenMark]

    func normalized() -> ScreenExplanation {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let speech = Self.spoken(speech)
        return ScreenExplanation(
            title: cleanedTitle.isEmpty ? "On your screen" : cleanedTitle,
            speech: speech,
            annotations: Array(annotations.map { $0.asFraction() }.compactMap { $0.drawable() }.prefix(8))
        )
    }

    /// Moves marks from image fractions into fractions of the whole screen.
    func placed(in region: CGRect, on screenSize: CGSize) -> ScreenExplanation {
        guard screenSize.width > 1, screenSize.height > 1, region.width > 1, region.height > 1 else { return self }
        let scaleX = region.width / screenSize.width
        let scaleY = region.height / screenSize.height
        let originX = region.minX / screenSize.width
        let originY = region.minY / screenSize.height
        let marks = annotations.map { mark in
            var copy = mark
            switch mark.shape {
            case "arrow":
                copy.x = originX + mark.x * scaleX
                copy.y = originY + mark.y * scaleY
                copy.width = originX + mark.width * scaleX
                copy.height = originY + mark.height * scaleY
            default:
                copy.x = originX + mark.x * scaleX
                copy.y = originY + mark.y * scaleY
                copy.width = mark.width * scaleX
                copy.height = mark.height * scaleY
            }
            return copy
        }
        return ScreenExplanation(title: title, speech: speech, annotations: marks)
    }

    private static func spoken(_ text: String) -> String {
        var speech = text
        let patterns = [
            #"\[[^\]\n]{0,180}\]"#,
            #"(?i)\b(circle|rectangle|rect|arrow|box|highlight)\s+at\s*\([^)]*\)"#,
            #"(?i)\(\s*\d*\.?\d+\s*,\s*\d*\.?\d+\s*,\s*\d*\.?\d+\s*,\s*\d*\.?\d+\s*\)"#
        ]
        for pattern in patterns {
            guard let regex = try? Regex(pattern) else { continue }
            speech = speech.replacing(regex, with: "")
        }
        speech = speech.replacingOccurrences(of: ", .", with: ".")
        speech = speech.replacingOccurrences(of: ",.", with: ".")
        while speech.contains("  ") {
            speech = speech.replacingOccurrences(of: "  ", with: " ")
        }
        return speech.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(from modelText: String) -> ScreenExplanation {
        let trimmed = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = jsonObject(from: trimmed) {
            let title = string(object["title"]) ?? "On your screen"
            var speech = string(object["speech"]) ?? string(object["answer"]) ?? string(object["explanation"]) ?? ""
            let rawMarks = object["annotations"] as? [Any] ?? object["marks"] as? [Any] ?? []
            let marks = rawMarks.compactMap(mark(from:))
            if speech.isEmpty {
                speech = marks.isEmpty ? "" : "I marked the relevant part of the screen."
            }
            return ScreenExplanation(title: title, speech: speech, annotations: marks).normalized()
        }

        let title = firstString(named: "title", in: trimmed) ?? "On your screen"
        if let speech = firstString(named: "speech", in: trimmed)
            ?? firstString(named: "answer", in: trimmed)
            ?? firstString(named: "explanation", in: trimmed) {
            return ScreenExplanation(title: title, speech: speech, annotations: []).normalized()
        }

        if trimmed.contains("{") {
            return ScreenExplanation(title: "On your screen", speech: "", annotations: [])
        }
        return ScreenExplanation(title: "On your screen", speech: trimmed, annotations: []).normalized()
    }

    private static func jsonObject(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        let slice = String(text[start...])
        if let object = decodeObject(slice) { return object }
        guard let end = slice.lastIndex(of: "}") else { return decodeObject(repair(slice)) }
        if let object = decodeObject(String(slice[...end])) { return object }
        return decodeObject(repair(slice))
    }

    private static func decodeObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    /// Closes a JSON object that ran out of tokens mid-reply.
    private static func repair(_ json: String) -> String {
        var text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, last == "," || last == ":" {
            text.removeLast()
        }
        var escaped = false
        var inString = false
        var braces = 0
        var brackets = 0
        for character in text {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" {
                inString.toggle()
                continue
            }
            if inString { continue }
            switch character {
            case "{": braces += 1
            case "}": braces = max(0, braces - 1)
            case "[": brackets += 1
            case "]": brackets = max(0, brackets - 1)
            default: break
            }
        }
        if inString { text += "\"" }
        if brackets > 0 { text += String(repeating: "]", count: brackets) }
        if braces > 0 { text += String(repeating: "}", count: braces) }
        return text
    }

    private static func firstString(named name: String, in text: String) -> String? {
        let pattern = "\"\(name)\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        let raw = String(text[capture])
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func mark(from value: Any) -> ScreenMark? {
        guard let dict = value as? [String: Any] else { return nil }
        let shape = string(dict["shape"]) ?? string(dict["type"]) ?? "circle"
        let label = string(dict["label"]) ?? string(dict["text"]) ?? ""
        let horizontalStart = number(dict["left"] ?? dict["x"])
        let verticalStart = number(dict["top"] ?? dict["y"])
        let isArrow = ["arrow", "line", "pointer"].contains(shape.lowercased())

        if dict["right"] != nil || dict["bottom"] != nil {
            let horizontalEnd = number(dict["right"] ?? dict["x2"] ?? dict["endX"])
            let verticalEnd = number(dict["bottom"] ?? dict["y2"] ?? dict["endY"])
            if isArrow {
                return ScreenMark(shape: shape, x: horizontalStart, y: verticalStart, width: horizontalEnd, height: verticalEnd, label: label)
            }
            let left = min(horizontalStart, horizontalEnd)
            let right = max(horizontalStart, horizontalEnd)
            let top = min(verticalStart, verticalEnd)
            let bottom = max(verticalStart, verticalEnd)
            return ScreenMark(shape: shape, x: left, y: top, width: right - left, height: bottom - top, label: label)
        }

        return ScreenMark(
            shape: shape,
            x: horizontalStart,
            y: verticalStart,
            width: number(dict["width"] ?? dict["w"] ?? dict["endX"] ?? dict["x2"]),
            height: number(dict["height"] ?? dict["h"] ?? dict["endY"] ?? dict["y2"]),
            label: label
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let text as String:
            Double(text) ?? 0
        default:
            0
        }
    }
}
