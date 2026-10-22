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

    @Published var phase: Phase = .idle
    @Published var statusText = ""
    @Published var lastQuestion = ""
    @Published var answerTitle = ""
    @Published var answerSpeech = ""
    @Published var isListening = false
    @Published var whiteboardAvailable = false
    @Published var whiteboardVisible = false
    @Published private(set) var permissionRefresh = 0

    let screenCaptureReadyAtLaunch = CGPreflightScreenCaptureAccess()

    private let capture = ScreenCaptureManager()
    private let explainer = ScreenExplainer()
    private let overlay: ScreenOverlayController
    private let whiteboard = WhiteboardController()
    private var warmSession: LanguageModelSession?
    var hideInterface: (() -> Void)?
    var showInterface: (() -> Void)?
    private var work: Task<Void, Never>?
    private var requestID = UUID()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        overlay = ScreenOverlayController(settings: speechSettings)
        whiteboard.onVisibilityChange = { [weak self] visible in
            self?.whiteboardVisible = visible
        }
        speech.onFinished = { [weak self] text in
            self?.askAboutScreen(text)
        }
        speechSettings.$speaksAnswers
            .dropFirst()
            .sink { [weak self] speaks in
                if !speaks {
                    self?.overlay.stopSpeaking()
                }
            }
            .store(in: &cancellables)
        speech.$isRecording
            .sink { [weak self] recording in
                self?.isListening = recording
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

    func askAboutScreen(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speech.cancelListening()

        let id = UUID()
        requestID = id
        work?.cancel()
        work = Task { @MainActor in
            await self.run(trimmed, id: id)
        }
    }

    func explainCurrentScreen() {
        askAboutScreen("What is on my screen?")
    }

    func setDrawingsVisible(_ visible: Bool) {
        overlay.setDrawingsVisible(visible)
    }

    func dismissExplanation() {
        overlay.dismiss()
        clearWhiteboard()
        phase = .idle
        statusText = ""
        answerTitle = ""
        answerSpeech = ""
    }

    func showWhiteboard() {
        whiteboard.showAgain()
    }

    func isWhiteboardWindow(_ window: NSWindow?) -> Bool {
        whiteboard.isWindow(window)
    }

    func repeatAnswer() {
        overlay.speak(answerSpeech, force: true)
    }

    func previewSpeech() {
        overlay.speak("This is how Secretary will sound.", force: true)
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

    private func run(_ question: String, id: UUID) async {
        overlay.dismiss()
        clearWhiteboard()
        guard requestID == id else { return }
        lastQuestion = question
        answerTitle = ""
        answerSpeech = ""
        phase = .thinking
        statusText = "Looking at your screen…"
        hideInterface?()
        defer { showInterface?() }

        do {
            try await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, requestID == id else { return }
            let captured: CapturedScreen
            do {
                captured = try await capture.capture()
            } catch is CancellationError {
                return
            } catch {
                throw screenCaptureNeedsRelaunch ? ScreenCaptureError.permission : error
            }
            guard !Task.isCancelled, requestID == id else { return }

            statusText = "Answering…"
            showInterface?()
            var spokeEarly = false
            let explanation = try await explainer.explain(
                question: question,
                image: captured.image,
                settings: settings
            ) { [weak self] sentence in
                guard let self else { return }
                spokeEarly = true
                if self.answerSpeech.isEmpty {
                    self.answerSpeech = sentence
                } else {
                    self.answerSpeech += " \(sentence)"
                }
                if self.answerTitle.isEmpty {
                    self.answerTitle = "On your screen"
                }
                self.phase = .presenting
                self.overlay.enqueue(sentence)
            }
            guard !Task.isCancelled, requestID == id else { return }

            let ready = explanation.normalized().placed(in: captured.region, on: captured.screen.frame.size)
            guard !ready.speech.isEmpty else {
                throw ExplainerError.message("The model didn't say anything about this screen.")
            }
            if !ready.whiteboardHTML.isEmpty {
                whiteboard.present(html: ready.whiteboardHTML, title: ready.title, on: captured.screen)
                whiteboardAvailable = true
            }
            phase = .presenting
            statusText = ready.annotations.isEmpty ? "" : "Drew \(ready.annotations.count) on your screen."
            answerTitle = ready.title
            answerSpeech = ready.speech
            overlay.present(explanation: ready, on: captured.screen, speaks: !spokeEarly)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            let message = failureMessage(for: error)
            phase = .failed
            statusText = message
            answerTitle = "Something went wrong"
            answerSpeech = message
            overlay.dismiss()
            clearWhiteboard()
        }
    }

    private func clearWhiteboard() {
        whiteboard.dismiss()
        whiteboardAvailable = false
        whiteboardVisible = false
    }

    private func failureMessage(for error: Error) -> String {
        error.localizedDescription
    }

    private func prewarmModel() {
        guard SystemLanguageModel.default.availability == .available else { return }
        let model = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: ExplainerPrompt.behavior
        )
        warmSession = model
        model.prewarm()
    }
}
