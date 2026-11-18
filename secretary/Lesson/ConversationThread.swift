//
//  ConversationThread.swift
//  secretary
//

import Foundation

/// The conversation the person can talk back into. A new topic starts a new one.
nonisolated struct ConversationThread {
    struct Turn {
        var fromPerson: Bool
        var text: String
    }

    /// Past this many turns, the oldest are folded into the summary.
    static let longLength = 16
    /// How many recent turns stay word for word after folding.
    static let keptLength = 8

    var id = UUID()
    /// One line naming what the conversation is about.
    var topic = ""
    /// What the folded-away turns covered.
    var summary = ""
    var turns: [Turn] = []

    var isOpen: Bool { !turns.isEmpty || !summary.isEmpty }

    mutating func addPerson(_ text: String) {
        turns.append(Turn(fromPerson: true, text: text))
    }

    /// Lines Secretary speaks in a row are one turn.
    mutating func addSecretary(_ line: String) {
        if let last = turns.last, !last.fromPerson {
            turns[turns.count - 1].text += " \(line)"
        } else {
            turns.append(Turn(fromPerson: false, text: line))
        }
    }

    static func transcript(of turns: some Sequence<Turn>) -> String {
        turns.map { "\($0.fromPerson ? "Person" : "Secretary"): \($0.text)" }.joined(separator: "\n")
    }
}
