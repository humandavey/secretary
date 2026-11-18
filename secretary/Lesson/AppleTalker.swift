//
//  AppleTalker.swift
//  secretary
//

import AppKit
import FoundationModels

/// Apple's models can't follow the lesson format reliably yet, so they answer about the screen in speech only.
struct AppleTalker {
    func answer(_ question: String, about image: CGImage, using provider: ModelSettings.Provider) async throws -> String {
        if provider == .privateCloud {
            return try await answer(question, about: image, model: PrivateCloudComputeLanguageModel(), edges: [1400, 960])
        }
        return try await answer(question, about: image, model: SystemLanguageModel.default, edges: [1024, 640])
    }

    /// Tries the screenshot at each size in turn, stepping down when it is too large for the model.
    private func answer<Model: LanguageModel>(
        _ question: String,
        about image: CGImage,
        model: Model,
        edges: [CGFloat]
    ) async throws -> String {
        try requireAvailable(model)
        guard model.capabilities.contains(.vision) else {
            throw ModelError.message("This Apple model can't see images. Switch to an API key in Secretary's model settings.")
        }
        for edge in edges {
            do {
                let session = LanguageModelSession(model: model, instructions: TutorPrompt.talkOnly)
                let response = try await session.respond(
                    options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 220)
                ) {
                    "Question: \(question)\nThe image is the entire screen."
                    Attachment(image.fitted(maxEdge: edge)).label("screen")
                }
                let speech = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !speech.isEmpty else {
                    throw ModelError.message("The model didn't say anything about this screen.")
                }
                return speech
            } catch let error as LanguageModelError {
                guard case .contextSizeExceeded = error, edge != edges.last else { throw describe(error) }
            }
        }
        throw ModelError.message("The model couldn't look at that screenshot.")
    }

    private func requireAvailable<Model: LanguageModel>(_ model: Model) throws {
        if let system = model as? SystemLanguageModel, !system.isAvailable {
            throw ModelError.message("The on-device model isn't available. Turn on Apple Intelligence, or choose Private Cloud or an API key.")
        }
        if let cloud = model as? PrivateCloudComputeLanguageModel, !cloud.isAvailable {
            throw ModelError.message("Private Cloud Compute isn't available. Turn on Apple Intelligence, or use an API key.")
        }
    }

    private func describe(_ error: LanguageModelError) -> ModelError {
        switch error {
        case .contextSizeExceeded:
            .message("That screenshot is too large for this model. Try Private Cloud, or an API key, in the model settings.")
        case .rateLimited:
            .message("The model is busy right now. Wait a moment and ask again.")
        case .guardrailViolation, .refusal:
            .message("The Apple model declined to answer that. An API key in the model settings can try instead.")
        case .timeout:
            .message("The model took too long. Ask again.")
        default:
            .message(error.localizedDescription)
        }
    }
}
