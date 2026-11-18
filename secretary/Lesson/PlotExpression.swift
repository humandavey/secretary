//
//  PlotExpression.swift
//  secretary
//

import CoreGraphics
import Foundation

/// A formula in x, such as "sin(x)" or "x^2 - 3x", that the model asks the app to graph.
/// Parsed here because the text comes from a model and must not reach a general evaluator.
nonisolated struct PlotExpression {
    fileprivate indirect enum Node {
        case number(Double)
        case variable
        case negate(Node)
        case binary(Character, Node, Node)
        case call(String, Node)
    }

    private let root: Node

    init?(_ source: String) {
        var parser = Parser(source)
        guard let root = parser.expression(), parser.atEnd else { return nil }
        self.root = root
    }

    func value(at x: Double) -> Double {
        Self.evaluate(root, x)
    }

    private static func evaluate(_ node: Node, _ x: Double) -> Double {
        switch node {
        case .number(let value):
            return value
        case .variable:
            return x
        case .negate(let inner):
            return -evaluate(inner, x)
        case .binary(let operation, let left, let right):
            let a = evaluate(left, x)
            let b = evaluate(right, x)
            switch operation {
            case "+": return a + b
            case "-": return a - b
            case "*": return a * b
            case "/": return a / b
            default: return pow(a, b)
            }
        case .call(let name, let argument):
            return apply(name, evaluate(argument, x))
        }
    }

    fileprivate static let functionNames = [
        "asin", "acos", "atan", "sinh", "cosh", "tanh", "sqrt", "log10", "log2",
        "sin", "cos", "tan", "exp", "abs", "log", "ln"
    ]

    private static func apply(_ name: String, _ value: Double) -> Double {
        switch name {
        case "sin": sin(value)
        case "cos": cos(value)
        case "tan": tan(value)
        case "asin": asin(value)
        case "acos": acos(value)
        case "atan": atan(value)
        case "sinh": sinh(value)
        case "cosh": cosh(value)
        case "tanh": tanh(value)
        case "exp": exp(value)
        case "ln": log(value)
        case "log", "log10": log10(value)
        case "log2": log2(value)
        case "sqrt": sqrt(value)
        default: abs(value)
        }
    }
}

private nonisolated struct Parser {
    private let characters: [Character]
    private var index = 0

    init(_ source: String) {
        var text = source.lowercased()
        for (found, replacement) in [("**", "^"), ("−", "-"), ("×", "*"), ("·", "*"), ("÷", "/"), ("π", "pi")] {
            text = text.replacingOccurrences(of: found, with: replacement)
        }
        // "y = x^2" and "f(x) = x^2" mean the right-hand side.
        if let equals = text.lastIndex(of: "=") {
            text = String(text[text.index(after: equals)...])
        }
        characters = Array(text.filter { !$0.isWhitespace })
    }

    var atEnd: Bool { index == characters.count }

    private var next: Character? { index < characters.count ? characters[index] : nil }

    mutating func expression() -> PlotExpression.Node? {
        guard var left = term() else { return nil }
        while let operation = next, operation == "+" || operation == "-" {
            index += 1
            guard let right = term() else { return nil }
            left = .binary(operation, left, right)
        }
        return left
    }

    private mutating func term() -> PlotExpression.Node? {
        guard var left = signed() else { return nil }
        while let character = next {
            if character == "*" || character == "/" {
                index += 1
                guard let right = signed() else { return nil }
                left = .binary(character, left, right)
            } else if character.isLetter || character.isNumber || character == "(" || character == "." {
                // 2x, 3(x + 1), and x sin(x) multiply without a sign.
                guard let right = power() else { return nil }
                left = .binary("*", left, right)
            } else {
                break
            }
        }
        return left
    }

    private mutating func signed() -> PlotExpression.Node? {
        if next == "-" {
            index += 1
            return signed().map { .negate($0) }
        }
        if next == "+" {
            index += 1
            return signed()
        }
        return power()
    }

    private mutating func power() -> PlotExpression.Node? {
        guard let base = atom() else { return nil }
        guard next == "^" else { return base }
        index += 1
        guard let exponent = signed() else { return nil }
        return .binary("^", base, exponent)
    }

    private mutating func atom() -> PlotExpression.Node? {
        guard let character = next else { return nil }
        if character == "(" {
            return parenthesized()
        }
        if character.isNumber || character == "." {
            let start = index
            while let digit = next, digit.isNumber || digit == "." {
                index += 1
            }
            return Double(String(characters[start..<index])).map { .number($0) }
        }
        for name in PlotExpression.functionNames where starts(with: name + "(") {
            index += name.count
            return parenthesized().map { .call(name, $0) }
        }
        if starts(with: "pi") {
            index += 2
            return .number(.pi)
        }
        if character == "x" {
            index += 1
            return .variable
        }
        if character == "e" {
            index += 1
            return .number(M_E)
        }
        return nil
    }

    private mutating func parenthesized() -> PlotExpression.Node? {
        guard next == "(" else { return nil }
        index += 1
        guard let inner = expression(), next == ")" else { return nil }
        index += 1
        return inner
    }

    private func starts(with word: String) -> Bool {
        let wanted = Array(word)
        guard index + wanted.count <= characters.count else { return false }
        return Array(characters[index..<(index + wanted.count)]) == wanted
    }
}

/// The line of a graph in its own units, and the ranges its axes cover.
nonisolated struct PlotCurve {
    /// Runs of points. A formula breaks into several where it is undefined or jumps.
    var segments: [[CGPoint]] = []
    var x: ClosedRange<Double> = 0...1
    var y: ClosedRange<Double> = 0...1

    init?(expression: String, domain: [Double], data: [CGPoint]) {
        if data.count >= 2 {
            segments = [data.filter { $0.x.isFinite && $0.y.isFinite }]
        } else {
            guard let formula = PlotExpression(expression) else { return nil }
            let low = domain.first ?? -5
            let high = domain.count > 1 ? domain[1] : 5
            guard low.isFinite, high.isFinite, low < high else { return nil }
            let steps = 240
            var run: [CGPoint] = []
            for step in 0...steps {
                let x = low + (high - low) * Double(step) / Double(steps)
                let y = formula.value(at: x)
                if y.isFinite {
                    run.append(CGPoint(x: x, y: y))
                } else if !run.isEmpty {
                    segments.append(run)
                    run = []
                }
            }
            if !run.isEmpty { segments.append(run) }
        }

        let points = segments.joined()
        guard points.count >= 2,
              let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(), minX < maxX else { return nil }
        x = Double(minX)...Double(maxX)

        let heights = points.map { Double($0.y) }.sorted()
        var low = heights[0]
        var high = heights[heights.count - 1]
        if data.count < 2 {
            // 1/x and tan(x) shoot off to infinity. Frame the bulk of the curve and let the rest run off the edge.
            let lowBulk = heights[heights.count / 10]
            let highBulk = heights[heights.count * 9 / 10]
            let bulk = highBulk - lowBulk
            if bulk > 0, high - low > 20 * bulk {
                low = lowBulk - 1.5 * bulk
                high = highBulk + 1.5 * bulk
                segments = segments.flatMap { Self.split($0, whereJumpExceeds: high - low) }
            }
        }
        if low == high {
            low -= 1
            high += 1
        }
        let padding = (high - low) * 0.08
        y = (low - padding)...(high + padding)
    }

    /// Breaks a run where the curve leaps past an asymptote, so no line is drawn across the gap.
    private static func split(_ run: [CGPoint], whereJumpExceeds limit: Double) -> [[CGPoint]] {
        var pieces: [[CGPoint]] = []
        var piece: [CGPoint] = []
        for point in run {
            if let last = piece.last, abs(Double(point.y - last.y)) > limit {
                pieces.append(piece)
                piece = []
            }
            piece.append(point)
        }
        pieces.append(piece)
        return pieces.filter { $0.count >= 2 }
    }
}
