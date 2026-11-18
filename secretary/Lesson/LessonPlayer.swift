//
//  LessonPlayer.swift
//  secretary
//

import AppKit

/// Performs a lesson: speaks each beat's line and draws that beat's ink while the line is said.
@MainActor
final class LessonPlayer {
    private let voice: SpeechOutput
    private let settings: SpeechSettings
    private let overlay: ScreenOverlayController
    private let board: BoardController

    private(set) var isPlaying = false
    private var lesson: Lesson?
    private var screen: NSScreen?
    /// What was drawn before this lesson started, so a replay can start from the same picture.
    private var before: [InkAction] = []
    private var index = 0
    private var run = UUID()
    private var waitingOnVoice = false
    private var openedBoard = false
    private var onLine: ((String) -> Void)?
    private var onFinished: (() -> Void)?

    init(voice: SpeechOutput, settings: SpeechSettings, overlay: ScreenOverlayController, board: BoardController) {
        self.voice = voice
        self.settings = settings
        self.overlay = overlay
        self.board = board
    }

    /// Everything drawn right now, on the screen and on the board.
    var drawings: [InkAction] {
        overlay.items + board.canvas.items
    }

    /// `onLine` is called as each line starts. `onFinished` is called when the last beat ends.
    func play(
        _ lesson: Lesson,
        on screen: NSScreen,
        onLine: @escaping (String) -> Void,
        onFinished: @escaping () -> Void
    ) {
        stop()
        self.lesson = lesson
        self.screen = screen
        before = drawings
        self.onLine = onLine
        self.onFinished = onFinished
        start()
    }

    /// Plays the same lesson again from the picture it started on.
    func replay() {
        guard lesson != nil, let screen else { return }
        stop()
        onLine = nil
        onFinished = nil
        overlay.show(before.filter { $0.on == .screen }, on: screen)
        board.canvas.show(before.filter { $0.on == .board })
        start()
    }

    /// Stops talking and leaves the ink as it stands, with the current beat's drawing finished.
    func stop() {
        run = UUID()
        waitingOnVoice = false
        voice.stop()
        overlay.finishAnimations()
        board.canvas.finishAnimations()
        isPlaying = false
    }

    /// Stops, and removes everything from the screen and the board.
    func clear() {
        stop()
        lesson = nil
        before = []
        overlay.clear()
        board.reset()
    }

    /// Speech was switched off mid-line. That line will never report finishing, so move on by the clock.
    func voiceSwitchedOff() {
        voice.stop()
        guard isPlaying, waitingOnVoice else { return }
        waitingOnVoice = false
        advance(after: 0.6)
    }

    private func start() {
        index = 0
        openedBoard = false
        isPlaying = true
        playBeat()
    }

    private func playBeat() {
        guard let lesson, let screen, lesson.beats.indices.contains(index) else {
            isPlaying = false
            let finished = onFinished
            onFinished = nil
            finished?()
            return
        }
        let beat = lesson.beats[index]
        let inkCount = beat.actions.filter(\.draws).count
        let duration = beat.say.isEmpty ? Double(max(1, inkCount)) * 0.9 : spokenDuration(of: beat.say)
        draw(beat.actions, over: duration, title: lesson.title, on: screen)

        guard !beat.say.isEmpty else {
            advance(after: duration)
            return
        }
        onLine?(beat.say)
        guard settings.speaksAnswers else {
            advance(after: duration)
            return
        }
        let run = self.run
        waitingOnVoice = true
        voice.speak(beat.say) { [weak self] in
            guard let self, self.run == run else { return }
            self.waitingOnVoice = false
            self.index += 1
            self.playBeat()
        }
    }

    private func advance(after delay: TimeInterval) {
        let run = self.run
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.run == run else { return }
            self.index += 1
            self.playBeat()
        }
    }

    /// Spreads the beat's ink across the time its line takes to say.
    private func draw(_ actions: [InkAction], over duration: TimeInterval, title: String, on screen: NSScreen) {
        let slot = duration / Double(max(1, actions.filter(\.draws).count))
        var drawn = 0
        for action in actions {
            switch (action.on, action.type) {
            case (.screen, .clear):
                overlay.clear()
            case (.board, .clear):
                board.canvas.removeAll()
            case (.screen, .open):
                break
            case (.board, .open):
                openBoard(title: title, on: screen)
            default:
                let canvas: InkCanvas
                if action.on == .board {
                    openBoard(title: title, on: screen)
                    canvas = board.canvas
                } else {
                    canvas = overlay.canvas(on: screen)
                }
                // A pen stroke that takes a whole long sentence looks stalled, so each item has a ceiling.
                canvas.add(action, over: min(slot * 0.85, 1.6), after: Double(drawn) * slot)
                drawn += 1
            }
        }
    }

    /// Opens the board once per play. If the person closes it mid-lesson, it stays closed.
    private func openBoard(title: String, on screen: NSScreen) {
        guard !openedBoard else { return }
        openedBoard = true
        board.open(title: title, on: screen)
    }

    /// The synthesizer does not say how long a line will take, so estimate from its length and the speed setting.
    private func spokenDuration(of line: String) -> TimeInterval {
        min(14, max(1, Double(line.count) / (15 * settings.speed) + 0.3))
    }
}
