//
//  SpeechSettings.swift
//  secretary
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class SpeechSettings: ObservableObject {
    struct VoiceOption: Identifiable {
        let id: String
        let title: String
    }

    @Published var voiceIdentifier: String {
        didSet { defaults.set(voiceIdentifier, forKey: Keys.voice) }
    }

    @Published var speed: Double {
        didSet { defaults.set(speed, forKey: Keys.speed) }
    }

    @Published var pitch: Double {
        didSet { defaults.set(pitch, forKey: Keys.pitch) }
    }

    @Published var speaksAnswers: Bool {
        didSet { defaults.set(speaksAnswers, forKey: Keys.speaks) }
    }

    let voices: [VoiceOption]

    private let defaults = UserDefaults.standard

    init() {
        let storedVoice = defaults.string(forKey: Keys.voice) ?? ""
        if storedVoice.isEmpty || AVSpeechSynthesisVoice(identifier: storedVoice) != nil {
            voiceIdentifier = storedVoice
        } else {
            voiceIdentifier = ""
        }
        speed = (defaults.object(forKey: Keys.speed) as? Double) ?? 1
        pitch = (defaults.object(forKey: Keys.pitch) as? Double) ?? 1
        speaksAnswers = (defaults.object(forKey: Keys.speaks) as? Bool) ?? true
        voices = Self.installedVoices()
    }

    static var maximumSpeed: Double {
        let normal = AVSpeechUtteranceDefaultSpeechRate
        guard normal > 0 else { return 2 }
        return Double(AVSpeechUtteranceMaximumSpeechRate / normal)
    }

    var speedLabel: String {
        String(format: "%.2f×", speed)
    }

    var pitchLabel: String {
        String(format: "%.2f", pitch)
    }

    var voice: AVSpeechSynthesisVoice? {
        if !voiceIdentifier.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return chosen
        }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        return voices.first { $0.language.hasPrefix("en") && $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    var utteranceRate: Float {
        let scaled = Float(speed) * AVSpeechUtteranceDefaultSpeechRate
        return min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, scaled))
    }

    var pitchMultiplier: Float {
        Float(min(1.5, max(0.75, pitch)))
    }

    private static func installedVoices() -> [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { lhs, rhs in
                let lhsEnglish = lhs.language.hasPrefix("en")
                let rhsEnglish = rhs.language.hasPrefix("en")
                if lhsEnglish != rhsEnglish { return lhsEnglish }
                if lhs.quality != rhs.quality { return rank(lhs.quality) > rank(rhs.quality) }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { voice in
                VoiceOption(id: voice.identifier, title: title(for: voice))
            }
    }

    private static func title(for voice: AVSpeechSynthesisVoice) -> String {
        let language = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        let quality = qualityName(voice.quality)
        if quality.isEmpty || voice.name.localizedCaseInsensitiveContains(quality) {
            return "\(voice.name) · \(language)"
        }
        return "\(voice.name) · \(language) · \(quality)"
    }

    private static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: ""
        }
    }

    private static func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: 3
        case .enhanced: 2
        default: 1
        }
    }

    private enum Keys {
        static let voice = "secretary.speech.voice"
        static let speed = "secretary.speech.speed"
        static let pitch = "secretary.speech.pitch"
        static let speaks = "secretary.speech.speaks"
    }
}
