//
//  ModelClient.swift
//  secretary
//

import AppKit
import Foundation

nonisolated enum ModelError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

/// Where an OpenAI-style request goes.
nonisolated struct ModelEndpoint {
    var baseURL: String
    var modelName: String
    var apiKey: String
}

/// Sends one chat completion to an OpenAI-style API and returns the text of the reply.
struct ModelClient {
    /// The JSON shape a reply must have, for servers that enforce one.
    struct Schema {
        var name: String
        var body: [String: Any]
    }

    let endpoint: ModelEndpoint

    func reply(
        system: String,
        user: String,
        image: CGImage? = nil,
        schema: Schema,
        maxTokens: Int
    ) async throws -> String {
        let modelName = endpoint.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseText = endpoint.baseURL.lowercased()
        if apiKey.isEmpty, !baseText.contains("localhost"), !baseText.contains("127.0.0.1") {
            throw ModelError.message("Paste an API key in the Model section.")
        }
        guard !modelName.isEmpty else {
            throw ModelError.message("Enter a model name. For example, gpt-4.1-mini, or a local vision model such as qwen2.5vl.")
        }
        guard let base = URL(string: endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = base.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw ModelError.message("Enter a base URL such as https://api.openai.com/v1.")
        }

        var content: [[String: Any]] = [["type": "text", "text": user]]
        if let image {
            guard let jpeg = image.jpegData(maxEdge: 1600, quality: 0.9) else {
                throw ModelError.message("Secretary couldn't prepare the screenshot.")
            }
            let url = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
            content.append(["type": "image_url", "image_url": ["url": url, "detail": "high"]])
        }
        let messages: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": content]
        ]
        let format: [String: Any] = ["name": schema.name, "strict": true, "schema": schema.body]
        let responseFormat: [String: Any] = ["type": "json_schema", "json_schema": format]

        // Servers disagree on these three fields. Each one is dropped or renamed once if the server objects to it.
        var tokenField = "max_tokens"
        var sendsTemperature = true
        var sendsSchema = true
        for _ in 0..<4 {
            var body: [String: Any] = ["model": modelName, "messages": messages, tokenField: maxTokens]
            if sendsTemperature {
                body["temperature"] = 0
            }
            if sendsSchema {
                body["response_format"] = responseFormat
            }

            let (data, response) = try await send(body, to: completionsURL(from: base), apiKey: apiKey)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            if status == 400 {
                if tokenField == "max_tokens", text.localizedCaseInsensitiveContains("max_tokens") {
                    tokenField = "max_completion_tokens"
                    continue
                }
                if sendsTemperature, text.localizedCaseInsensitiveContains("temperature") {
                    sendsTemperature = false
                    continue
                }
                if sendsSchema, text.localizedCaseInsensitiveContains("response_format")
                    || text.localizedCaseInsensitiveContains("json_schema") {
                    sendsSchema = false
                    continue
                }
            }
            guard (200..<300).contains(status) else {
                throw ModelError.message("The model request failed (\(status)). \(text.prefix(240))")
            }
            return try replyText(in: data)
        }
        throw ModelError.message("The model rejected the request.")
    }

    private func completionsURL(from base: URL) -> URL {
        if base.path.hasSuffix("/chat/completions") { return base }
        return base.appending(path: "chat/completions")
    }

    private func send(_ body: [String: Any], to endpoint: URL, apiKey: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await URLSession(configuration: .ephemeral).data(for: request)
    }

    private func replyText(in data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelError.message("The model returned something Secretary couldn't read.")
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            throw ModelError.message(message)
        }
        guard let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw ModelError.message("The model returned no answer.")
        }
        var text = ""
        if let string = message["content"] as? String {
            text = string
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        guard !text.isEmpty else { throw ModelError.message("The model returned an empty answer.") }
        return text
    }
}
