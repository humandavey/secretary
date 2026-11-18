//
//  Lesson.swift
//  secretary
//

import CoreGraphics
import Foundation

/// One thing drawn on the screen or on the whiteboard.
nonisolated struct InkAction: Codable, Equatable {
    enum Surface: String, Codable {
        case screen
        case board
    }

    enum Kind: String, Codable, CaseIterable {
        case stroke
        case arrow
        case circle
        case rectangle
        case text
        case latex
        case plot
        case open
        case clear
    }

    var on: Surface
    var type: Kind
    /// Fractions of the surface, measured from its top-left corner.
    var points: [CGPoint] = []
    /// Words for text, LaTeX source for latex, or an expression in x for a plot.
    var text = ""
    /// The x range of an expression plot.
    var domain: [Double] = []
    /// Values to connect, for a plot of data.
    var data: [CGPoint] = []

    /// False for the two actions that change a surface without adding ink.
    var draws: Bool { type != .open && type != .clear }

    /// Clamps points to the surface. Returns nil for an action that has nothing to draw.
    func prepared() -> InkAction? {
        var action = self
        action.points = points.map { point in
            CGPoint(x: Self.fraction(point.x), y: Self.fraction(point.y))
        }
        action.text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch type {
        case .clear:
            return action
        case .open:
            return on == .board ? action : nil
        case .stroke, .arrow, .circle, .rectangle:
            return action.points.count >= 2 ? action : nil
        case .text:
            return !action.points.isEmpty && !action.text.isEmpty ? action : nil
        case .latex:
            action.text = Self.bareLatex(action.text)
            return on == .board && !action.points.isEmpty && !action.text.isEmpty ? action : nil
        case .plot:
            let plots = data.count >= 2 || !action.text.isEmpty
            return on == .board && action.points.count >= 2 && plots ? action : nil
        }
    }

    private static func fraction(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return (min(1, max(0, value)) * 1000).rounded() / 1000
    }

    /// Models often wrap math in dollar signs or \( \) even when asked for the bare source.
    private static func bareLatex(_ source: String) -> String {
        var latex = source
        for (open, close) in [("$$", "$$"), ("$", "$"), ("\\[", "\\]"), ("\\(", "\\)")] {
            if latex.hasPrefix(open), latex.hasSuffix(close), latex.count > open.count + close.count {
                latex = String(latex.dropFirst(open.count).dropLast(close.count))
            }
        }
        return latex.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension InkAction {
    private enum CodingKeys: String, CodingKey {
        case on, type, points, text, domain, data
    }

    /// A model without a strict schema may leave out the fields an action does not use.
    /// Points are `[x, y]` pairs, matching the lesson schema sent to the API.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        on = try container.decode(Surface.self, forKey: .on)
        type = try container.decode(Kind.self, forKey: .type)
        points = try container.decodeIfPresent([PointPair].self, forKey: .points)?.map(\.point) ?? []
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        domain = try container.decodeIfPresent([Double].self, forKey: .domain) ?? []
        data = try container.decodeIfPresent([PointPair].self, forKey: .data)?.map(\.point) ?? []
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(on, forKey: .on)
        try container.encode(type, forKey: .type)
        try container.encode(points.map(PointPair.init), forKey: .points)
        try container.encode(text, forKey: .text)
        try container.encode(domain, forKey: .domain)
        try container.encode(data.map(PointPair.init), forKey: .data)
    }
}

/// One `[x, y]` pair in lesson JSON. CGPoint's own Codable uses `{x,y}`, which the schema rejects.
private nonisolated struct PointPair: Codable {
    var point: CGPoint

    private enum CodingKeys: String, CodingKey {
        case x, y
    }

    init(_ point: CGPoint) {
        self.point = point
    }

    init(from decoder: Decoder) throws {
        if var values = try? decoder.unkeyedContainer() {
            let x = try values.decode(Double.self)
            let y = try values.decode(Double.self)
            point = CGPoint(x: x, y: y)
            return
        }
        // Servers that drop the schema sometimes emit {"x":…,"y":…} instead.
        let values = try decoder.container(keyedBy: CodingKeys.self)
        point = CGPoint(x: try values.decode(Double.self, forKey: .x), y: try values.decode(Double.self, forKey: .y))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(Double(point.x))
        try values.encode(Double(point.y))
    }
}

/// An explanation the app performs: spoken lines, each with the ink that appears while it is said.
nonisolated struct Lesson: Codable, Equatable {
    struct Beat: Codable, Equatable {
        var say: String
        var actions: [InkAction] = []
    }

    var title: String
    /// One line naming what the conversation is about.
    var topic: String
    var beats: [Beat]

    /// Reads the JSON object in a model's reply.
    static func decode(from reply: String) throws -> Lesson {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else {
            throw ModelError.message("The model didn't return a lesson.")
        }
        do {
            return try JSONDecoder().decode(Lesson.self, from: Data(reply[start...end].utf8))
        } catch {
            throw ModelError.message("The model returned a lesson Secretary couldn't read.")
        }
    }

    /// Trims the spoken lines and drops ink that cannot be drawn.
    /// Screen ink needs a screenshot to aim at, so it is dropped when there is none.
    func prepared(allowsScreenInk: Bool) -> Lesson {
        var lesson = self
        lesson.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        lesson.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        lesson.beats = beats.compactMap { beat in
            let say = beat.say.trimmingCharacters(in: .whitespacesAndNewlines)
            let actions = beat.actions
                .compactMap { $0.prepared() }
                .filter { allowsScreenInk || $0.on == .board }
            return say.isEmpty && actions.isEmpty ? nil : Beat(say: say, actions: actions)
        }
        return lesson
    }

    /// A lesson with no drawings, one beat per sentence.
    static func spoken(_ answer: String, title: String) -> Lesson {
        var sentences: [String] = []
        answer.enumerateSubstrings(in: answer.startIndex..., options: .bySentences) { sentence, _, _, _ in
            let trimmed = sentence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { sentences.append(trimmed) }
        }
        return Lesson(title: title, topic: "", beats: sentences.map { Beat(say: $0) })
    }
}

extension Lesson.Beat {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        say = try container.decode(String.self, forKey: .say)
        actions = try container.decodeIfPresent([InkAction].self, forKey: .actions) ?? []
    }
}

extension Lesson {
    /// A fixed lesson that needs no model, for checking how a lesson feels.
    static let demo = Lesson(
        title: "A thrown ball",
        topic: "",
        beats: [
            Beat(
                say: "This is how a lesson plays. I can draw right on your screen while I talk.",
                actions: [
                    InkAction(on: .screen, type: .stroke, points: loop(center: CGPoint(x: 0.5, y: 0.42), radius: CGSize(width: 0.11, height: 0.09))),
                    InkAction(on: .screen, type: .text, points: [CGPoint(x: 0.455, y: 0.535)], text: "Drawn on your screen")
                ]
            ),
            Beat(
                say: "When a picture helps, I open a whiteboard.",
                actions: [
                    InkAction(on: .board, type: .text, points: [CGPoint(x: 0.06, y: 0.05)], text: "Height of a thrown ball"),
                    InkAction(on: .board, type: .stroke, points: [CGPoint(x: 0.06, y: 0.13), CGPoint(x: 0.2, y: 0.137), CGPoint(x: 0.36, y: 0.128), CGPoint(x: 0.52, y: 0.134)])
                ]
            ),
            Beat(
                say: "Throw a ball straight up, and its height is a quadratic in time.",
                actions: [
                    InkAction(on: .board, type: .latex, points: [CGPoint(x: 0.06, y: 0.19)], text: #"h(t) = v_0 t - \frac{1}{2} g t^2"#)
                ]
            ),
            Beat(
                say: "Plotted, it rises, slows to a stop at the peak, and falls back down.",
                actions: [
                    InkAction(on: .board, type: .plot, points: [CGPoint(x: 0.1, y: 0.42), CGPoint(x: 0.72, y: 0.92)], text: "20x - 4.9x^2", domain: [0, 4.1]),
                    InkAction(on: .board, type: .arrow, points: [CGPoint(x: 0.8, y: 0.36), CGPoint(x: 0.66, y: 0.38), CGPoint(x: 0.44, y: 0.445)]),
                    InkAction(on: .board, type: .text, points: [CGPoint(x: 0.82, y: 0.33)], text: "peak")
                ]
            )
        ]
    )

    private static func loop(center: CGPoint, radius: CGSize) -> [CGPoint] {
        // A little more than one turn, so the ends overlap like a pen circling something.
        (0...26).map { step in
            let angle = Double(step) / 24 * 2 * .pi - .pi / 2
            return CGPoint(x: center.x + radius.width * cos(angle), y: center.y + radius.height * sin(angle))
        }
    }
}
