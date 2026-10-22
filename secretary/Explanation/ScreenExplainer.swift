//
//  ScreenExplainer.swift
//  secretary
//

import AppKit
import Foundation
import FoundationModels

enum ExplainerError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

enum ExplainerPrompt {
    static let behavior = """
    You are Secretary. A person is asking about everything visible on their Mac screen.
    Answer in two or three spoken sentences. Mention colors, pictures, windows, and layout when that answers the question.
    annotations are circles, rectangles, and arrows you choose to draw on the screenshot.
    Add a mark when they ask you to circle or point at something, or when a mark makes the answer easier to see.
    Leave annotations empty when no drawing is needed.
    \(coordinates)
    Labels are two or three words, or empty. Never put coordinates in speech.
    """

    static let apiBehavior = """
    You are Secretary. A person is asking about everything visible on their Mac screen.
    annotations are circles, rectangles, and arrows you choose to draw on the screenshot.
    Add a mark when they ask you to circle or point at something, or when a mark makes the answer easier to see.
    Leave annotations empty when no drawing is needed.
    \(coordinates)
    Labels are two or three words, or empty. Never put coordinates, HTML, or SVG in speech.

    Open a whiteboard when they ask you to explain, diagram, compare, chart, sketch, or teach something, or when a picture would teach the idea better than words. Leave the whiteboard out for a simple question about what is on the screen.

    Reply with no markdown.
    First, one JSON object and nothing else:
    {"title": "short title", "speech": "spoken answer", "annotations": [{"shape": "circle", "left": 300, "top": 500, "right": 340, "bottom": 560, "label": "icon"}]}
    That example is an icon from 30% to 34% across and from 50% to 56% down. Read the real edges from the magenta grid. Do not copy these numbers.
    shape is circle, rectangle, or arrow. Use an empty annotations array when no mark is needed.

    When you do not open a whiteboard, speech is two or three spoken sentences.
    When you open a whiteboard, speech is the explanation. Use as many sentences as the concept needs, and walk through what is on the board. Do not read markup aloud.

    To open a whiteboard, put a newline after the JSON, then <<<BOARD>>>, then an HTML fragment, then <<<END>>>.
    The fragment is inline HTML, CSS, and SVG only. No script, no iframe, and no http or https URL.
    Draw charts and diagrams as SVG with a viewBox. Use rect, line, path, and text for bars, lines, arrows, and labels. Do not use a chart library.
    Use h1, p, ul, and svg. A shared stylesheet already styles those. You may add one style block for the diagram.
    """

    static let coordinates = """
    The screenshot has a magenta measuring grid that is not really on the user's screen. Never mention it and never draw a mark on a grid line.
    Numbers along the top are the horizontal scale. Numbers along the left are the vertical scale. Lines are every 100, from 0 at the top-left to 1000 at the bottom-right. Estimate between the lines.
    For a circle or rectangle, return the object's outermost edges, read from that grid:
    left is the number above the object's leftmost pixel. right is the number above its rightmost pixel.
    top is the number beside its topmost pixel. bottom is the number beside its bottommost pixel.
    left is smaller than the object's horizontal middle. If left is the middle, the circle is drawn too far right.
    Example: an icon from 30% to 34% across and from 50% to 56% down is left=300, top=500, right=340, bottom=560.
    For an arrow, left and top are the tail, and right and bottom are where the head lands.
    """

    static func question(_ question: String) -> String {
        "Question: \(question)\nThe image is the entire screen. Magenta numbers are a measuring grid, not part of the screen."
    }
}

@MainActor
struct ScreenExplainer {
    func explain(
        question: String,
        image: CGImage,
        settings: ModelSettings,
        onSentence: (@MainActor (String) -> Void)? = nil
    ) async throws -> ScreenExplanation {
        switch settings.provider {
        case .onDevice:
            let attempts = [
                Attempt(maxEdge: 1024, includeSchema: true),
                Attempt(maxEdge: 640, includeSchema: true)
            ]
            return try await explainWithApple(
                question: question,
                image: image,
                model: SystemLanguageModel.default,
                attempts: attempts,
                onSentence: onSentence
            )
        case .privateCloud:
            let model = PrivateCloudComputeLanguageModel()
            return try await explainWithApple(
                question: question,
                image: image,
                model: model,
                attempts: [
                    Attempt(maxEdge: 1400, includeSchema: true),
                    Attempt(maxEdge: 960, includeSchema: true)
                ],
                onSentence: onSentence
            )
        case .api:
            return try await explainWithAPI(
                question: question,
                image: image,
                settings: settings
            )
        }
    }

    private struct Attempt {
        var maxEdge: CGFloat
        var includeSchema: Bool
        var reasoning: ContextOptions.ReasoningLevel? = nil
    }

    private func explainWithApple<Model: LanguageModel>(
        question: String,
        image: CGImage,
        model: Model,
        attempts: [Attempt],
        onSentence: (@MainActor (String) -> Void)?
    ) async throws -> ScreenExplanation {
        try requireAvailable(model)
        guard model.capabilities.contains(.vision) else {
            throw ExplainerError.message("This Apple model can't see images. Switch to an API key in Secretary's model settings.")
        }

        var lastContextError: LanguageModelError?
        var sawParseFailure = false
        for attempt in attempts {
            let scaled = image.fitted(maxEdge: attempt.maxEdge).withMeasurementGrid()
            do {
                let explanation = try await respond(
                    question: question,
                    image: scaled,
                    model: model,
                    includeSchema: attempt.includeSchema,
                    reasoning: attempt.reasoning,
                    onSentence: onSentence
                )
                if !explanation.speech.isEmpty { return explanation }
                sawParseFailure = true
                break
            } catch let error as GeneratedContent.ParsingError {
                let recovered = ScreenExplanation.parse(from: error.rawContent).normalized()
                if !recovered.speech.isEmpty { return recovered }
                sawParseFailure = true
                break
            } catch let error as LanguageModelError {
                guard isContextLimit(error), attempt.maxEdge != attempts.last?.maxEdge else { throw describe(error) }
                lastContextError = error
            }
        }
        if sawParseFailure {
            return try await plainAnswer(
                question: question,
                image: image.fitted(maxEdge: attempts.first?.maxEdge ?? 1024),
                model: model
            )
        }
        if let lastContextError {
            throw describe(lastContextError)
        }
        throw ExplainerError.message("The model couldn't look at that screenshot.")
    }

    private func respond<Model: LanguageModel>(
        question: String,
        image: CGImage,
        model: Model,
        includeSchema: Bool,
        reasoning: ContextOptions.ReasoningLevel?,
        onSentence: (@MainActor (String) -> Void)?
    ) async throws -> ScreenExplanation {
        let session = LanguageModelSession(model: model, instructions: ExplainerPrompt.behavior)
        let stream = try session.streamResponse(
            generating: GeneratedExplanation.self,
            options: GenerationOptions(temperature: 0, maximumResponseTokens: 800),
            contextOptions: ContextOptions(includeSchemaInPrompt: includeSchema, reasoningLevel: reasoning)
        ) {
            ExplainerPrompt.question(question)
            Attachment(image).label("screen")
        }

        var title = ""
        var speech = ""
        var rawJSON = ""
        var spokenOffset = 0
        for try await snapshot in stream {
            rawJSON = snapshot.rawContent.jsonString
            if let partialTitle = snapshot.content.title, !partialTitle.isEmpty {
                title = partialTitle
            }
            guard let partial = snapshot.content.speech, !partial.isEmpty else { continue }
            speech = partial
            let spokenIndex = speech.index(speech.startIndex, offsetBy: min(spokenOffset, speech.count))
            var cursor = spokenIndex
            let fresh = Self.completedSentences(in: speech, spokenThrough: &cursor)
            spokenOffset = speech.distance(from: speech.startIndex, to: cursor)
            for sentence in fresh {
                onSentence?(sentence)
            }
        }
        let tailStart = speech.index(speech.startIndex, offsetBy: min(spokenOffset, speech.count))
        let tail = speech[tailStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            onSentence?(String(tail))
        }
        let parsed = ScreenExplanation.parse(from: rawJSON)
        let explanation = ScreenExplanation(
            title: title.isEmpty ? parsed.title : title,
            speech: speech.isEmpty ? parsed.speech : speech,
            annotations: parsed.annotations
        ).normalized()
        guard !explanation.speech.isEmpty else {
            throw ExplainerError.message("The model didn't say anything about this screen.")
        }
        return explanation
    }

    /// Returns sentences that end with punctuation and have not been spoken yet.
    private static func completedSentences(in speech: String, spokenThrough index: inout String.Index) -> [String] {
        guard index < speech.endIndex else { return [] }
        var sentences: [String] = []
        var cursor = index
        while cursor < speech.endIndex {
            let next = speech[cursor...].firstIndex { character in
                character == "." || character == "!" || character == "?"
            }
            guard let next else { break }
            let sentence = speech[cursor...next].trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = speech.index(after: next)
            if sentence.count > 1 {
                sentences.append(sentence)
            }
        }
        index = cursor
        return sentences
    }

    private func plainAnswer<Model: LanguageModel>(
        question: String,
        image: CGImage,
        model: Model
    ) async throws -> ScreenExplanation {
        let session = LanguageModelSession(
            model: model,
            instructions: "You are Secretary. Answer in two or three plain sentences about the screenshot. No JSON and no coordinates."
        )
        let response = try await session.respond(
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 220)
        ) {
            ExplainerPrompt.question(question)
            Attachment(image).label("screen")
        }
        let speech = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speech.isEmpty else {
            throw ExplainerError.message("The model didn't say anything about this screen.")
        }
        return ScreenExplanation(title: "On your screen", speech: speech, annotations: []).normalized()
    }

    private func requireAvailable<Model: LanguageModel>(_ model: Model) throws {
        if let system = model as? SystemLanguageModel, !system.isAvailable {
            throw ExplainerError.message("The on-device model isn't available. Turn on Apple Intelligence, or choose Private Cloud or an API key.")
        }
        if let cloud = model as? PrivateCloudComputeLanguageModel, !cloud.isAvailable {
            throw ExplainerError.message("Private Cloud Compute isn't available. Turn on Apple Intelligence, or use an API key.")
        }
    }

    private func isContextLimit(_ error: LanguageModelError) -> Bool {
        if case .contextSizeExceeded = error { return true }
        return false
    }

    private func describe(_ error: LanguageModelError) -> ExplainerError {
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

    private func explainWithAPI(
        question: String,
        image: CGImage,
        settings: ModelSettings
    ) async throws -> ScreenExplanation {
        let modelName = settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseText = settings.baseURL.lowercased()
        if apiKey.isEmpty, !baseText.contains("localhost"), !baseText.contains("127.0.0.1") {
            throw ExplainerError.message("Paste an OpenAI API key in the Model section. Secretary sends the whole screenshot to that model.")
        }
        guard !modelName.isEmpty else {
            throw ExplainerError.message("Enter a model name. For example, gpt-4.1-mini, or a local vision model such as qwen2.5vl.")
        }
        guard let base = URL(string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = base.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw ExplainerError.message("Enter a base URL such as https://api.openai.com/v1.")
        }
        guard let jpeg = image.fitted(maxEdge: 1600).withMeasurementGrid().jpegData(maxEdge: 2000, quality: 0.9) else {
            throw ExplainerError.message("Secretary couldn't prepare the screenshot.")
        }

        let endpoint = completionsURL(from: base)
        var tokenField = "max_tokens"
        for _ in 0..<2 {
            let (data, response) = try await send(
                endpoint: endpoint,
                modelName: modelName,
                apiKey: apiKey,
                question: question,
                jpeg: jpeg,
                tokenField: tokenField
            )
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 400, tokenField == "max_tokens", let body = String(data: data, encoding: .utf8),
               body.localizedCaseInsensitiveContains("max_tokens") {
                tokenField = "max_completion_tokens"
                continue
            }
            guard (200..<300).contains(status) else {
                let snippet = String(data: data, encoding: .utf8)?.prefix(240) ?? ""
                throw ExplainerError.message("The model request failed (\(status)). \(snippet)")
            }
            return try decodeAnswer(data)
        }
        throw ExplainerError.message("The model rejected the request.")
    }

    private func completionsURL(from base: URL) -> URL {
        if base.path.hasSuffix("/chat/completions") { return base }
        return base.appending(path: "chat/completions")
    }

    private func send(
        endpoint: URL,
        modelName: String,
        apiKey: String,
        question: String,
        jpeg: Data,
        tokenField: String
    ) async throws -> (Data, URLResponse) {
        let body: [String: Any] = [
            "model": modelName,
            "temperature": 0,
            tokenField: 8000,
            "messages": [
                [
                    "role": "system",
                    "content": ExplainerPrompt.apiBehavior
                ],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": ExplainerPrompt.question(question)],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())", "detail": "high"]]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let session = URLSession(configuration: .ephemeral)
        return try await session.data(for: request)
    }

    private func decodeAnswer(_ data: Data) throws -> ScreenExplanation {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExplainerError.message("The model returned something Secretary couldn't read.")
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            throw ExplainerError.message(message)
        }
        guard
            let choices = object["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            throw ExplainerError.message("The model returned no answer.")
        }
        let text = messageText(message["content"])
        guard !text.isEmpty else { throw ExplainerError.message("The model returned an empty answer.") }
        return ScreenExplanation.parse(from: text)
    }

    private func messageText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}
