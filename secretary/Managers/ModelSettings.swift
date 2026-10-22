//
//  ModelSettings.swift
//  secretary
//

import Combine
import Foundation
import FoundationModels

@MainActor
final class ModelSettings: ObservableObject {
    enum Provider: String, CaseIterable, Identifiable {
        case onDevice
        case privateCloud
        case api

        var id: String { rawValue }

        var title: String {
            switch self {
            case .onDevice: "On this Mac"
            case .privateCloud: "Private Cloud"
            case .api: "OpenAI or other API"
            }
        }
    }

    @Published var provider: Provider {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
    }

    @Published var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Keys.baseURL) }
    }

    @Published var modelName: String {
        didSet { defaults.set(modelName, forKey: Keys.modelName) }
    }

    @Published var apiKey: String {
        didSet { KeychainStore.save(apiKey, account: Keys.apiKeyAccount) }
    }

    private let defaults = UserDefaults.standard
    private lazy var privateCloud = PrivateCloudComputeLanguageModel()

    init() {
        let storedProvider = defaults.string(forKey: Keys.provider) ?? ""
        let migrated = defaults.bool(forKey: Keys.migratedToVision)
        if !migrated {
            provider = .api
            defaults.set(Provider.api.rawValue, forKey: Keys.provider)
            defaults.set(true, forKey: Keys.migratedToVision)
        } else {
            provider = Provider(rawValue: storedProvider) ?? .api
        }
        baseURL = defaults.string(forKey: Keys.baseURL) ?? "https://api.openai.com/v1"
        modelName = defaults.string(forKey: Keys.modelName) ?? "gpt-4.1-mini"
        apiKey = KeychainStore.load(account: Keys.apiKeyAccount) ?? ""
    }

    var statusNote: String {
        switch provider {
        case .onDevice:
            switch SystemLanguageModel.default.availability {
            case .available:
                "Apple's on-device model sees the screenshot, but it is weak at colors and at choosing where to draw. An API key is the better choice."
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    "This Mac can't run the on-device model. Use Private Cloud or an API key."
                case .appleIntelligenceNotEnabled:
                    "Turn on Apple Intelligence in System Settings, or switch to an API key."
                case .modelNotReady:
                    "The on-device model is still preparing. Try again in a moment."
                @unknown default:
                    "The on-device model isn't available."
                }
            }
        case .privateCloud:
            switch privateCloud.availability {
            case .available:
                "Apple's larger model sees the whole screenshot through Private Cloud Compute, not a third-party API."
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    "Private Cloud Compute isn't available on this Mac."
                case .systemNotReady:
                    "Private Cloud Compute isn't ready yet."
                @unknown default:
                    "Private Cloud Compute isn't available."
                }
            }
        case .api:
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !baseURL.contains("localhost")
                ? "Paste an OpenAI API key. Secretary sends a screenshot of the whole screen, and the model decides what to circle."
                : "Secretary sends a screenshot of the whole screen. The model answers and decides what to circle."
        }
    }

    func applyOpenAIPreset() {
        provider = .api
        baseURL = "https://api.openai.com/v1"
        modelName = "gpt-4.1-mini"
    }

    func applyOllamaPreset() {
        provider = .api
        baseURL = "http://localhost:11434/v1"
        modelName = "qwen2.5vl"
    }

    private enum Keys {
        static let provider = "secretary.model.provider"
        static let baseURL = "secretary.model.baseURL"
        static let modelName = "secretary.model.name"
        static let apiKeyAccount = "apiKey"
        static let migratedToVision = "secretary.model.migratedToVision"
    }
}
