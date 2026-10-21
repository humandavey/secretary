//
//  SpeechManager.swift
//  secretary
//
//  Created by Davey Adams on 10/21/26.
//

import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
class SpeechManager: ObservableObject {
    @Published var transcribedText: String = ""
    @Published var isRecording: Bool = false
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    func toggleListening() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        stopRecording()
        
        SFSpeechRecognizer.requestAuthorization { authStatus in
            guard authStatus == .authorized else { return }
            
            Task { @MainActor in
                do {
                    try self.setupAudioAndStart()
                } catch {
                    print("Error setting up local speech recognition: \(error)")
                    self.stopRecording()
                }
            }
        }
    }
    
    private func setupAudioAndStart() throws {
        isRecording = true
        transcribedText = ""
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        
        recognitionRequest.requiresOnDeviceRecognition = true
        recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        
        let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardwareFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) ?? hardwareFormat
        
        inputNode.reset()
        
        let request = recognitionRequest
        
        try inputNode.installAudioTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { readOnlyBuffer, _ in
            let pcmBuffer = AVAudioPCMBuffer(copying: readOnlyBuffer)
            
            Task { @MainActor in
                request.append(pcmBuffer)
            }
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result {
                self.transcribedText = result.bestTranscription.formattedString
            }
            if error != nil || result?.isFinal == true {
                self.stopRecording()
            }
        }
    }
    
    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }
}
