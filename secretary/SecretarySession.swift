//
//  SecretarySession.swift
//  secretary
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import FoundationModels

@MainActor
final class SecretarySession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case thinking
        case presenting
        case failed
    }

    let speech = SpeechManager()
    let settings = ModelSettings()
    let speechSettings = SpeechSettings()
    let memory = MemoryStore()

    @Published var phase: Phase = .idle
    @Published var statusText = ""
    @Published var lastQuestion = ""
    @Published var answerTitle = ""
    @Published var answerSpeech = ""
    @Published var isListening = false
    @Published var whiteboardAvailable = false
    @Published var whiteboardVisible = false
    /// The conversation the next message may carry on.
    @Published private(set) var thread = ConversationThread()
    @Published private(set) var permissionRefresh = 0

    let screenCaptureReadyAtLaunch = CGPreflightScreenCaptureAccess()

    private let capture = ScreenCaptureManager()
    private let voice: SpeechOutput
    private let board = BoardController()
    private let player: LessonPlayer
    private var warmSession: LanguageModelSession?
    var hideInterface: (() -> Void)?
    var showInterface: (() -> Void)?
    private var work: Task<Void, Never>?
    private var requestID = UUID()
    /// The display the screen ink in this conversation was drawn for.
    private var inkScreen: NSScreen?
    /// What the person said and what Secretary has said back so far, until memory has seen it.
    private var exchange: (said: String, spoken: [String])?
    /// Memory updates and summaries run one at a time, after the lesson they belong to.
    private var housekeeping: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        voice = SpeechOutput(settings: speechSettings)
        player = LessonPlayer(voice: voice, settings: speechSettings, overlay: ScreenOverlayController(), board: board)
        board.onChange = { [weak self] opened, visible in
            self?.whiteboardAvailable = opened
            self?.whiteboardVisible = visible
        }
        speech.onFinished = { [weak self] text in
            self?.ask(text)
        }
        speechSettings.$speaksAnswers
            .dropFirst()
            .sink { [weak self] speaks in
                if !speaks {
                    self?.player.voiceSwitchedOff()
                }
            }
            .store(in: &cancellables)
        speech.$isRecording
            .sink { [weak self] recording in
                self?.isListening = recording
                if recording {
                    // Secretary stops talking the moment the person starts.
                    self?.interrupt()
                }
            }
            .store(in: &cancellables)
        Task { @MainActor in
            self.prewarmModel()
        }
    }

    var screenCaptureNeedsRelaunch: Bool {
        _ = permissionRefresh
        return !screenCaptureReadyAtLaunch && CGPreflightScreenCaptureAccess()
    }

    var screenCaptureMissing: Bool {
        _ = permissionRefresh
        return !CGPreflightScreenCaptureAccess()
    }

    /// Answers a message. `looksAtScreen` skips the question of whether the screen is needed.
    func ask(_ utterance: String, looksAtScreen: Bool = false) {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speech.cancelListening()

        let id = UUID()
        requestID = id
        work?.cancel()
        work = Task { @MainActor in
            await self.run(trimmed, looksAtScreen: looksAtScreen, id: id)
        }
    }

    func explainCurrentScreen() {
        ask("What is on my screen?", looksAtScreen: true)
    }

    /// Plays the built-in lesson, which needs no model.
    func playDemo() {
        cancelRequest()
        resetThread()
        guard let screen = capture.screenUnderPointer() else { return }
        lastQuestion = ""
        present(.demo, on: screen, answering: nil)
    }

    /// Takes the lesson off the screen. The conversation stays open.
    func dismissLesson() {
        cancelRequest()
        interrupt()
        player.clear()
        inkScreen = nil
        showIdle()
    }

    /// Forgets the conversation and clears everything it drew. Memory of the person is kept.
    func startNewThread() {
        cancelRequest()
        resetThread()
        showIdle()
    }

    func replayLesson() {
        player.replay()
    }

    func showWhiteboard() {
        board.showAgain()
    }

    func isWhiteboardWindow(_ window: NSWindow?) -> Bool {
        board.isWindow(window)
    }

    func previewSpeech() {
        player.stop()
        voice.speak("This is how Secretary will sound.", force: true)
    }

    func requestScreenCaptureAccess() {
        CGRequestScreenCaptureAccess()
        permissionRefresh += 1
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, error in
            let description = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let description {
                    self.phase = .failed
                    self.statusText = "Quit Secretary and open it again so screen recording can start. \(description)"
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: Answering

    private func run(_ utterance: String, looksAtScreen: Bool, id: UUID) async {
        interrupt()
        lastQuestion = utterance
        phase = .thinking
        statusText = "Thinking…"
        do {
            if settings.provider == .api {
                try await teach(utterance, looksAtScreen: looksAtScreen, id: id)
            } else {
                try await answerInSpeech(utterance, id: id)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            phase = .failed
            statusText = error.localizedDescription
        }
    }

    /// The full path: place the message in a conversation, look at the screen if it helps, then play a lesson.
    private func teach(_ utterance: String, looksAtScreen: Bool, id: UUID) async throws {
        let tutor = Tutor(client: ModelClient(endpoint: settings.endpoint))

        // With nothing open and the screen already asked for, there is nothing to decide.
        var route = Tutor.Route(continues: false, needsScreen: true)
        if thread.isOpen || !looksAtScreen {
            route = try await tutor.route(utterance, in: thread)
            try stillCurrent(id)
        }
        if !route.continues {
            resetThread()
        }

        var screenshot: CGImage?
        if route.needsScreen || looksAtScreen {
            statusText = "Looking at your screen…"
            let captured = try await captureScreen()
            try stillCurrent(id)
            screenshot = captured.image
            inkScreen = captured.screen
        }

        statusText = "Answering…"
        let reply = try await tutor.lesson(
            for: utterance,
            in: thread,
            drawings: player.drawings,
            memory: memory.promptText,
            screenshot: screenshot
        )
        try stillCurrent(id)

        let lesson = reply.prepared(allowsScreenInk: inkScreen != nil)
        guard !lesson.beats.isEmpty else {
            throw ModelError.message("The model didn't say anything.")
        }
        guard let screen = inkScreen ?? capture.screenUnderPointer() else {
            throw ScreenCaptureError.noDisplay
        }
        thread.addPerson(utterance)
        if !lesson.topic.isEmpty {
            thread.topic = lesson.topic
        }
        present(lesson, on: screen, answering: utterance)
    }

    /// Apple's models answer one question about the screen, aloud. No drawing, conversation, or memory.
    private func answerInSpeech(_ utterance: String, id: UUID) async throws {
        resetThread()
        statusText = "Looking at your screen…"
        let captured = try await captureScreen()
        try stillCurrent(id)
        statusText = "Answering…"
        let answer = try await AppleTalker().answer(utterance, about: captured.image, using: settings.provider)
        try stillCurrent(id)
        present(Lesson.spoken(answer, title: "On your screen"), on: captured.screen, answering: nil)
    }

    private func captureScreen() async throws -> CapturedScreen {
        hideInterface?()
        defer { showInterface?() }
        try await Task.sleep(for: .milliseconds(250))
        do {
            return try await capture.capture()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw screenCaptureNeedsRelaunch ? ScreenCaptureError.permission : error
        }
    }

    /// `utterance` is what this lesson answers. It is nil for a lesson that is not part of the conversation.
    private func present(_ lesson: Lesson, on screen: NSScreen, answering utterance: String?) {
        phase = .presenting
        statusText = ""
        answerTitle = lesson.title
        answerSpeech = ""
        exchange = utterance.map { (said: $0, spoken: []) }
        player.play(lesson, on: screen, onLine: { [weak self] line in
            guard let self else { return }
            self.answerSpeech += self.answerSpeech.isEmpty ? line : " \(line)"
            guard self.exchange != nil else { return }
            // The thread and memory get what was actually said, so a lesson cut short is recorded as cut short.
            self.exchange?.spoken.append(line)
            self.thread.addSecretary(line)
        }, onFinished: { [weak self] in
            self?.lessonEnded()
        })
    }

    /// Talking back stops the lesson where it is. What is drawn stays, as the picture the next turn starts from.
    private func interrupt() {
        player.stop()
        lessonEnded()
    }

    private func lessonEnded() {
        guard let exchange else { return }
        self.exchange = nil
        guard settings.provider == .api else { return }
        let threadID = thread.id
        let earlier = housekeeping
        housekeeping = Task { @MainActor [weak self] in
            await earlier?.value
            await self?.remember(exchange)
            await self?.foldThreadIfLong(threadID)
        }
    }

    private func resetThread() {
        interrupt()
        thread = ConversationThread()
        inkScreen = nil
        player.clear()
    }

    private func showIdle() {
        phase = .idle
        statusText = ""
        answerTitle = ""
        answerSpeech = ""
    }

    private func cancelRequest() {
        requestID = UUID()
        work?.cancel()
    }

    private func stillCurrent(_ id: UUID) throws {
        guard !Task.isCancelled, requestID == id else { throw CancellationError() }
    }

    // MARK: Memory and long conversations

    /// Lets the model revise the profile after an exchange. A failure here is not worth interrupting the person for.
    private func remember(_ exchange: (said: String, spoken: [String])) async {
        let tutor = Tutor(client: ModelClient(endpoint: settings.endpoint))
        let revision = memory.revision
        let revised = try? await tutor.revisedMemory(
            memory.entries,
            said: exchange.said,
            spoken: exchange.spoken.joined(separator: " ")
        )
        if let revised {
            memory.replace(with: revised, ifRevision: revision)
        }
    }

    /// Keeps a long conversation from carrying its whole history into every request.
    private func foldThreadIfLong(_ id: UUID) async {
        guard thread.id == id, thread.turns.count > ConversationThread.longLength else { return }
        let old = Array(thread.turns.dropLast(ConversationThread.keptLength))
        let tutor = Tutor(client: ModelClient(endpoint: settings.endpoint))
        guard let summary = try? await tutor.summary(of: old, after: thread.summary), thread.id == id else { return }
        thread.summary = summary
        thread.turns.removeFirst(min(old.count, thread.turns.count))
    }

    private func prewarmModel() {
        guard SystemLanguageModel.default.availability == .available else { return }
        let model = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: TutorPrompt.talkOnly
        )
        warmSession = model
        model.prewarm()
    }
}
