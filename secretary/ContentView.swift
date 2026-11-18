//
//  ContentView.swift
//  secretary
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var session: SecretarySession
    @ObservedObject var settings: ModelSettings
    @ObservedObject var speechSettings: SpeechSettings
    @ObservedObject var memory: MemoryStore
    @State private var question = ""

    init(session: SecretarySession) {
        _session = ObservedObject(wrappedValue: session)
        _settings = ObservedObject(wrappedValue: session.settings)
        _speechSettings = ObservedObject(wrappedValue: session.speechSettings)
        _memory = ObservedObject(wrappedValue: session.memory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            AnimatedButton(speech: session.speech)
                .frame(maxWidth: .infinity)

            status

            conversation

            questionField

            screenAccess

            DisclosureGroup("Memory") {
                memoryList
                    .padding(.top, 6)
            }

            DisclosureGroup("Model") {
                modelSettings
                    .padding(.top, 6)
            }

            DisclosureGroup("Speech") {
                speechControls
                    .padding(.top, 6)
            }
        }
        .padding()
        .frame(width: 320, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            Text("Secretary")
                .font(.headline)
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark")
            }
            .keyboardShortcut("q")
            .help("Quit Secretary")
        }
    }

    @ViewBuilder
    private var status: some View {
        if let warning = session.speech.warning {
            Text(warning)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        switch session.phase {
        case .thinking:
            if !session.lastQuestion.isEmpty {
                Text(session.lastQuestion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(session.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .presenting:
            if !session.answerTitle.isEmpty {
                Text(session.answerTitle)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Text(session.answerSpeech)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: session.whiteboardAvailable ? 360 : 180)
            if !session.statusText.isEmpty {
                Text(session.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if session.whiteboardAvailable {
                Text("Opened a whiteboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !session.whiteboardVisible {
                    Button("Show whiteboard") {
                        session.showWhiteboard()
                    }
                    .controlSize(.small)
                }
            }
            HStack {
                Button("Dismiss") {
                    session.dismissLesson()
                }
                Button("Replay") {
                    session.replayLesson()
                }
            }
            .controlSize(.small)
        case .failed:
            Text(session.statusText)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Button("Dismiss") {
                session.dismissLesson()
            }
            .controlSize(.small)
        case .idle:
            EmptyView()
        }
    }

    /// The open conversation, and the way out of it when Secretary carried on one that should have ended.
    @ViewBuilder
    private var conversation: some View {
        if session.thread.isOpen {
            HStack(alignment: .firstTextBaseline) {
                Text(session.thread.topic.isEmpty ? "In a conversation" : "Talking about \(session.thread.topic)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("New thread") {
                    session.startNewThread()
                }
                .controlSize(.small)
                .help("Forget this conversation and clear what it drew")
            }
        }
    }

    private var questionField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(session.thread.isOpen ? "Ask, or reply" : "Ask anything", text: $question)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitQuestion)

            HStack {
                Button("Ask", action: submitQuestion)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Explain this screen") {
                    session.explainCurrentScreen()
                }
                Button("Demo") {
                    session.playDemo()
                }
                .help("Play a short built-in lesson. It needs no model.")
            }
            .controlSize(.small)

            Text("Tap the orb and ask, or type. Secretary looks at your screen when the question needs it, and draws while it explains.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var memoryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if memory.entries.isEmpty {
                Text("Nothing yet. Secretary notes how you like to learn and what you keep coming back to.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(memory.entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.kind.title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(entry.text)
                                        .font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Button {
                                    memory.delete(entry)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Forget this")
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)

                Button("Forget everything") {
                    memory.clear()
                }
                .controlSize(.small)
            }

            Text("Kept on this Mac, and sent to your model with each question so it can teach the way you like. A new thread does not erase it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var screenAccess: some View {
        if session.screenCaptureMissing {
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen Recording is off, so Secretary can't see your screen yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow Screen Recording") {
                    session.requestScreenCaptureAccess()
                }
                .controlSize(.small)
            }
        } else if session.screenCaptureNeedsRelaunch {
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen Recording is allowed. Quit and reopen Secretary before the first capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Relaunch Secretary") {
                    session.relaunch()
                }
                .controlSize(.small)
            }
        }
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Model", selection: $settings.provider) {
                ForEach(ModelSettings.Provider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Text(settings.statusNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.provider == .api {
                TextField("Base URL", text: $settings.baseURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Model name", text: $settings.modelName)
                    .textFieldStyle(.roundedBorder)
                SecureField("API key", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("OpenAI", action: settings.applyOpenAIPreset)
                    Button("Ollama", action: settings.applyOllamaPreset)
                }
                .controlSize(.small)
                Text("The key stays in your Keychain. Leave it blank for a local server that doesn't need one.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var speechControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Voice", selection: $speechSettings.voiceIdentifier) {
                Text("Automatic").tag("")
                ForEach(speechSettings.voices) { voice in
                    Text(voice.title).tag(voice.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            HStack {
                Text("Speed")
                Spacer()
                Text(speechSettings.speedLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(value: $speechSettings.speed, in: 0.5...SpeechSettings.maximumSpeed, step: 0.05)

            HStack {
                Text("Pitch")
                Spacer()
                Text(speechSettings.pitchLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(value: $speechSettings.pitch, in: 0.75...1.5, step: 0.05)

            Toggle("Speak answers", isOn: $speechSettings.speaksAnswers)
                .font(.caption)
                .toggleStyle(.checkbox)

            Button("Preview voice") {
                session.previewSpeech()
            }
            .controlSize(.small)

            Text("Automatic uses an enhanced English voice when one is installed. More voices are in System Settings, Accessibility, Spoken Content.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submitQuestion() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        question = ""
        session.ask(trimmed)
    }
}
