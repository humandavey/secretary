//
//  MemoryStore.swift
//  secretary
//

import Combine
import Foundation

/// One thing Secretary remembers about the person.
nonisolated struct MemoryEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case learningStyle
        case interest
        case fact

        var title: String {
            switch self {
            case .learningStyle: "Learning style"
            case .interest: "Interest"
            case .fact: "Fact"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var text: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
    }
}

/// What Secretary knows about the person across conversations. It lives in one local file and nowhere else.
@MainActor
final class MemoryStore: ObservableObject {
    static let limit = 30

    @Published private(set) var entries: [MemoryEntry] = []
    /// Goes up whenever the profile changes, so a revision written against an older copy can be told apart.
    private(set) var revision = 0
    private let file: URL?

    nonisolated static var defaultFile: URL? {
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support?.appending(path: "Secretary").appending(path: "memory.json")
    }

    init(file: URL? = MemoryStore.defaultFile) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([MemoryEntry].self, from: data) {
            entries = saved
        }
    }

    /// The profile as lines for a prompt.
    var promptText: String {
        entries.map { "- \($0.kind.title): \($0.text)" }.joined(separator: "\n")
    }

    func delete(_ entry: MemoryEntry) {
        set(entries.filter { $0.id != entry.id })
    }

    func clear() {
        set([])
    }

    /// Takes the model's revised profile. A revision written before the person edited the profile is thrown away,
    /// because it would bring back whatever they just deleted.
    func replace(with revised: [MemoryEntry], ifRevision expected: Int) {
        guard expected == revision else { return }
        let cleaned = revised
            .map { MemoryEntry(kind: $0.kind, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
            .prefix(Self.limit)
        let unchanged = cleaned.count == entries.count
            && zip(cleaned, entries).allSatisfy { $0.kind == $1.kind && $0.text == $1.text }
        guard !unchanged else { return }
        set(Array(cleaned))
    }

    private func set(_ updated: [MemoryEntry]) {
        entries = updated
        revision += 1
        guard let file else { return }
        if updated.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(updated).write(to: file, options: .atomic)
    }
}
