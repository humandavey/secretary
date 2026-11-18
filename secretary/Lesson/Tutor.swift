//
//  Tutor.swift
//  secretary
//

import CoreGraphics
import Foundation

/// The model calls behind a lesson: where a new message belongs, the lesson itself, and the notes kept afterward.
struct Tutor {
    struct Route {
        /// The message carries on the open conversation.
        var continues: Bool
        /// Answering needs a look at the person's screen.
        var needsScreen: Bool
    }

    let client: ModelClient

    /// Decides whether a message carries on the open conversation, and whether it needs the screen.
    func route(_ utterance: String, in thread: ConversationThread) async throws -> Route {
        var message = "No conversation is open."
        if thread.isOpen {
            let recent = ConversationThread.transcript(of: thread.turns.suffix(6))
            message = "The open conversation is about: \(thread.topic)\nIts latest turns:\n\(recent)"
        }
        message += "\n\nNew message: \(utterance)"
        let reply = try await client.reply(
            system: TutorPrompt.router,
            user: message,
            schema: TutorPrompt.routeSchema,
            maxTokens: 400
        )
        guard let decision = Self.decode(RouteReply.self, from: reply) else {
            // An unreadable answer here should not cost the person their question.
            // Keeping the conversation and looking at the screen gives the lesson more to work with, never less.
            return Route(continues: thread.isOpen, needsScreen: true)
        }
        return Route(continues: thread.isOpen && decision.thread == "continue", needsScreen: decision.needsScreen)
    }

    /// Writes the lesson. The thread, the drawings on display, and the profile are its only context.
    func lesson(
        for utterance: String,
        in thread: ConversationThread,
        drawings: [InkAction],
        memory: String,
        screenshot: CGImage?
    ) async throws -> Lesson {
        var parts: [String] = []
        if !memory.isEmpty {
            parts.append("About this person. Let it shape how you teach, and do not mention it:\n\(memory)")
        }
        if thread.isOpen {
            var history = "The conversation so far:"
            if !thread.summary.isEmpty {
                history += "\nEarlier: \(thread.summary)"
            }
            parts.append("\(history)\n\(ConversationThread.transcript(of: thread.turns))")
        }
        if !drawings.isEmpty, let json = try? JSONEncoder().encode(drawings) {
            parts.append("Drawings now:\n\(String(decoding: json, as: UTF8.self))")
        }
        parts.append(screenshot == nil ? "No screenshot is attached." : "A screenshot of their whole screen is attached.")
        parts.append("They say: \(utterance)")

        let reply = try await client.reply(
            system: TutorPrompt.lesson,
            user: parts.joined(separator: "\n\n"),
            image: screenshot,
            schema: TutorPrompt.lessonSchema,
            maxTokens: 8000
        )
        return try Lesson.decode(from: reply)
    }

    /// Returns the whole profile as it should stand after this exchange, or nil when the reply can't be read.
    func revisedMemory(_ entries: [MemoryEntry], said: String, spoken: String) async throws -> [MemoryEntry]? {
        let profile = entries.isEmpty
            ? "(empty)"
            : entries.map { "- \($0.kind.rawValue): \($0.text)" }.joined(separator: "\n")
        let reply = try await client.reply(
            system: TutorPrompt.memory,
            user: "Current profile:\n\(profile)\n\nLatest exchange:\nPerson: \(said)\nSecretary: \(spoken)",
            schema: TutorPrompt.memorySchema,
            maxTokens: 1500
        )
        return Self.decode(MemoryReply.self, from: reply)?.entries
    }

    /// Folds older turns, and any earlier summary, into a few sentences.
    func summary(of turns: [ConversationThread.Turn], after earlier: String) async throws -> String? {
        var message = ConversationThread.transcript(of: turns)
        if !earlier.isEmpty {
            message = "Before this: \(earlier)\n\n\(message)"
        }
        let reply = try await client.reply(
            system: TutorPrompt.summary,
            user: message,
            schema: TutorPrompt.summarySchema,
            maxTokens: 400
        )
        let summary = Self.decode(SummaryReply.self, from: reply)?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary?.isEmpty == false ? summary : nil
    }

    private static func decode<Reply: Decodable>(_ type: Reply.Type, from reply: String) -> Reply? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(type, from: Data(reply[start...end].utf8))
    }
}

private nonisolated struct RouteReply: Decodable {
    var thread: String
    var needsScreen: Bool
}

private nonisolated struct MemoryReply: Decodable {
    var entries: [MemoryEntry]
}

private nonisolated struct SummaryReply: Decodable {
    var summary: String
}

enum TutorPrompt {
    static let lesson = """
    You are Secretary, a tutor who draws while talking. The person hears each line you say and watches your drawings appear as you say it, like a recorded tutoring video.

    Reply with one JSON object and nothing else:
    {"title": "...", "topic": "...", "beats": [{"say": "...", "actions": [...]}]}

    title is six words or fewer.
    topic is one line naming what this conversation is about.
    beats are the lesson in order. Each beat is one or two spoken sentences, plus the drawings that appear while they are said.
    A quick question gets one or two beats and often no drawings. An explanation gets as many beats as the idea needs, and each beat adds one step to the picture.
    say is plain spoken English. No markdown, no LaTeX, and no coordinates. Say what the drawing shows, not that you are drawing it.

    An action is {"on", "type", "points", "text", "domain", "data"}. Always include every field, with [] or "" for one that does not apply.
    on is "screen" to draw over the person's real screen, or "board" to draw on a whiteboard window.
    points are [x, y] pairs from 0 to 1 on that surface. [0, 0] is the top-left corner and [1, 1] is the bottom-right.

    type is one of:
    "stroke": a pen line through the points, in order, with straight segments between them. Use more points for a curve. Strokes are how you draw anything: bonds, rings, molecules, shapes, diagrams.
    "arrow": a stroke with an arrowhead at its last point.
    "circle": an ellipse filling the box whose opposite corners are the two points.
    "rectangle": a box with those two corners.
    "text": short writing whose top-left corner is the one point.
    "latex": board only. text is LaTeX math with no dollar signs, and its top-left corner is the one point.
    "plot": board only. A graph filling the box between two corner points. Give either text as a formula in x, such as "sin(x)" or "x^2 - 3x", with domain as [xMin, xMax], or data as the [x, y] values to connect.
    "open": board only. Shows the whiteboard without drawing on it.
    "clear": erases everything on that surface.

    The screen
    Draw on the screen only when a screenshot is attached, or to change screen drawings listed under "Drawings now". Points are fractions of the screenshot. In the beat where you mention something on the screen, circle it, box it, underline it, or point an arrow at it. Text on the screen is a label of a few words.

    The board
    Use the board when a drawing, an equation, or a graph teaches better than words alone. Leave it closed for a quick factual answer.
    The board is 4 wide by 3 tall. A line of text is about 0.07 tall and about 0.02 wide per character. An equation with a fraction or an integral is about 0.14 tall. Work from the top down, leave a gap between items, and keep everything between 0.04 and 0.96.

    Continuing a conversation
    "Drawings now" lists what is already on the screen and the board, as actions. It stays visible, so add to it and refer to it instead of drawing it again. To remove or change one thing, clear that surface and draw again what should stay. Clear the board when you need the room for something new.
    """

    static let router = """
    You sort one new message for a tutoring assistant. Reply with one JSON object and nothing else:
    {"thread": "continue" or "new", "needsScreen": true or false}

    thread is "continue" when the message follows from the open conversation: a follow-up question, a reaction, a correction, "go on", or a request to change what was drawn. It is "new" when the message starts a different subject, or when no conversation is open.
    needsScreen is true when answering takes a look at the person's screen: they say "this", "here", or "on my screen", or they ask about something they are looking at that the conversation does not already cover. It is false for a general question, and for a follow-up the conversation already answers.
    """

    static let memory = """
    You keep a short profile of one person for their tutoring assistant. You are given the current profile and the latest exchange. Reply with one JSON object and nothing else:
    {"entries": [{"kind": "learningStyle" or "interest" or "fact", "text": "..."}]}
    It is the whole profile as it should now stand.

    Most exchanges change nothing. Then return the profile exactly as it is.
    Change it only for something that will still matter in a month:
    learningStyle is how they like to be taught: pace, how visual to be, where to start, what they already know, and corrections to how you explain.
    interest is a subject or project they keep coming back to.
    fact is anything else lasting, such as a class they are in or a goal they named.
    A one-off question is not a memory.
    Rewrite an entry when the exchange corrects it. Drop an entry when they ask you to forget it, or when it is no longer true. When a new note is the same fact as an existing entry, merge it into that entry.
    Each entry is one short line. Keep at most 30.
    """

    static let summary = """
    Summarize this tutoring conversation in at most three sentences: what the person asked and what was explained. Reply with one JSON object and nothing else:
    {"summary": "..."}
    """

    static let talkOnly = "You are Secretary. Answer in two or three plain spoken sentences about the screenshot. No JSON and no coordinates."

    static let lessonSchema: ModelClient.Schema = {
        let pairs: [String: Any] = ["type": "array", "items": ["type": "array", "items": ["type": "number"]]]
        let action = object([
            "on": ["type": "string", "enum": ["screen", "board"]],
            "type": ["type": "string", "enum": InkAction.Kind.allCases.map(\.rawValue)],
            "points": pairs,
            "text": ["type": "string"],
            "domain": ["type": "array", "items": ["type": "number"]],
            "data": pairs
        ])
        let beat = object([
            "say": ["type": "string"],
            "actions": ["type": "array", "items": action]
        ])
        return ModelClient.Schema(name: "lesson", body: object([
            "title": ["type": "string"],
            "topic": ["type": "string"],
            "beats": ["type": "array", "items": beat]
        ]))
    }()

    static let routeSchema = ModelClient.Schema(name: "route", body: object([
        "thread": ["type": "string", "enum": ["continue", "new"]],
        "needsScreen": ["type": "boolean"]
    ]))

    static let memorySchema = ModelClient.Schema(name: "profile", body: object([
        "entries": [
            "type": "array",
            "items": object([
                "kind": ["type": "string", "enum": MemoryEntry.Kind.allCases.map(\.rawValue)],
                "text": ["type": "string"]
            ])
        ] as [String: Any]
    ]))

    static let summarySchema = ModelClient.Schema(name: "summary", body: object([
        "summary": ["type": "string"]
    ]))

    /// A strict JSON object: every property required, and nothing else allowed.
    private static func object(_ properties: [String: Any]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": Array(properties.keys).sorted(),
            "additionalProperties": false
        ]
    }
}
