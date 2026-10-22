//
//  SpeechManager.swift
//  secretary
//

import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
class SpeechManager: ObservableObject {
    @Published var transcribedText = ""
    @Published var isRecording = false
    @Published var warning: String?

    var onFinished: ((String) -> Void)?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var engineRunning = false
    private var tapInstalled = false
    private var armToken = UUID()

    func toggleListening() {
        if isRecording {
            endSession(submit: true)
        } else {
            arm()
        }
    }

    func cancelListening() {
        if isRecording {
            endSession(submit: false)
        } else {
            armToken = UUID()
        }
    }

    private func arm() {
        let token = UUID()
        armToken = token
        isRecording = true
        warning = nil

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self, self.armToken == token else { return }
                guard status == .authorized else {
                    self.isRecording = false
                    self.warning = "Secretary needs Speech Recognition permission to hear you."
                    return
                }
                do {
                    try self.beginEngine()
                } catch {
                    self.warning = error.localizedDescription
                    self.endSession(submit: false)
                }
            }
        }
    }

    private func beginEngine() throws {
        teardownAudio()
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw SpeechError.unavailable
        }

        isRecording = true
        transcribedText = ""
        warning = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw SpeechError.unavailable
        }
        let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardwareFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) ?? hardwareFormat

        inputNode.reset()
        let bufferSize = AVAudioFrameCount(hardwareFormat.sampleRate * 0.1)
        let tap: AVAudioNodeTapBlock = { [weak request] buffer, _ in
            guard buffer.frameLength > 0 else { return }
            let copy = AVAudioPCMBuffer(copying: buffer)
            guard copy.frameLength > 0 else { return }
            request?.append(copy)
        }
        // macOS 27 reports tap failure by throwing. The imported name is still the refined form, and the error slot is unused.
        do {
            try inputNode.__installTap(onBus: 0, bufferSize: bufferSize, format: recordingFormat, error: (), block: tap)
        } catch {
            try inputNode.__installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat, error: (), block: tap)
        }
        tapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
        engineRunning = true

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.engineRunning else { return }
                if let result {
                    self.transcribedText = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.endSession(submit: true)
                        return
                    }
                }
                if error != nil {
                    self.endSession(submit: false)
                }
            }
        }
    }

    private func endSession(submit: Bool) {
        armToken = UUID()
        let text = transcribedText
        let shouldSubmit = submit && engineRunning
        engineRunning = false
        teardownAudio()
        isRecording = false
        guard shouldSubmit else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onFinished?(trimmed)
        }
    }

    private func teardownAudio() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }
}

private enum SpeechError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "On-device speech recognition isn't available right now."
    }
}
