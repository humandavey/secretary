//
//  SpeechOutput.swift
//  secretary
//

import AVFoundation

@MainActor
final class SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()
    private let settings: SpeechSettings
    private let finish = SpeechFinishDelegate()

    init(settings: SpeechSettings) {
        self.settings = settings
        synthesizer.delegate = finish
    }

    func speak(_ text: String, force: Bool = false, whenFinished: (@MainActor () -> Void)? = nil) {
        finish.set(nil)
        synthesizer.stopSpeaking(at: .immediate)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if let whenFinished {
                Task { @MainActor in whenFinished() }
            }
            return
        }
        guard force || settings.speaksAnswers else {
            if let whenFinished {
                Task { @MainActor in whenFinished() }
            }
            return
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = settings.voice
        utterance.rate = settings.utteranceRate
        utterance.pitchMultiplier = settings.pitchMultiplier
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        finish.arm(utterance, whenFinished)
        synthesizer.speak(utterance)
    }

    func stop() {
        finish.arm(nil, nil)
        synthesizer.stopSpeaking(at: .immediate)
    }
}

private final class SpeechFinishDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let lock = NSLock()
    private var active: AVSpeechUtterance?
    private var onFinish: (@MainActor () -> Void)?

    func set(_ callback: (@MainActor () -> Void)?) {
        arm(nil, callback)
    }

    func arm(_ utterance: AVSpeechUtterance?, _ callback: (@MainActor () -> Void)?) {
        lock.lock()
        active = utterance
        onFinish = callback
        lock.unlock()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        lock.lock()
        guard utterance === active else {
            lock.unlock()
            return
        }
        active = nil
        let callback = onFinish
        onFinish = nil
        lock.unlock()
        Task { @MainActor in callback?() }
    }
}
