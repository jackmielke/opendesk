import AVFoundation
import Speech
import SwiftUI

/// Push-to-talk speech-to-text: hold to talk, release to get the transcript.
/// Prefers on-device recognition, so dictated business data stays on the phone too.
@Observable
final class VoiceInput {
    var transcript = ""
    var isListening = false
    var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async {
        guard !isListening else { return }
        error = nil
        transcript = ""
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized else { error = "Allow speech recognition in Settings."; return }
        guard await AVAudioApplication.requestRecordPermission() else { error = "Allow microphone access in Settings."; return }
        guard let recognizer, recognizer.isAvailable else { error = "Speech recognition unavailable."; return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
            engine.prepare()
            try engine.start()
            isListening = true

            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                guard let self else { return }
                if let result { Task { @MainActor in self.transcript = result.bestTranscription.formattedString } }
                if err != nil || (result?.isFinal ?? false) { Task { @MainActor in self.teardown() } }
            }
        } catch {
            self.error = error.localizedDescription
            teardown()
        }
    }

    /// Stops listening and returns the final transcript once the recognizer settles.
    func stop() async -> String {
        request?.endAudio()
        try? await Task.sleep(for: .milliseconds(450))
        teardown()
        return transcript
    }

    private func teardown() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request = nil
        task?.cancel()
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// A mic button: press and hold to dictate, release to submit.
struct HoldToTalkButton: View {
    let voice: VoiceInput
    let onTranscript: (String) -> Void
    @State private var pressing = false

    var body: some View {
        Image(systemName: voice.isListening ? "waveform" : "mic.fill")
            .font(.title3)
            .symbolEffect(.variableColor.iterative, isActive: voice.isListening)
            .foregroundStyle(voice.isListening ? .red : Brand.ai)
            .frame(width: 34, height: 34)
            .background((voice.isListening ? Color.red : Brand.ai).opacity(0.15), in: Circle())
            .scaleEffect(pressing ? 1.15 : 1)
            .animation(.spring(duration: 0.2), value: pressing)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressing else { return }
                        pressing = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        Task { await voice.start() }
                    }
                    .onEnded { _ in
                        pressing = false
                        Task {
                            let text = await voice.stop()
                            if !text.trimmingCharacters(in: .whitespaces).isEmpty { onTranscript(text) }
                        }
                    }
            )
            .accessibilityLabel("Hold to talk")
    }
}
