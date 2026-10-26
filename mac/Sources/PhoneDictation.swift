import Foundation

/// Dictation from the phone during remote control: its microphone streams here as 16 kHz mono
/// 16-bit PCM and goes through a speech-to-text service (`SpeechEngine`). The words go back
/// to the phone's keyboard as they're recognised; the phone types them on the Mac when told to.
final class PhoneDictation {
    /// Words in progress for the phone to show; `done` once the dictation has wrapped up.
    var onLive: ((_ text: String, _ done: Bool) -> Void)?
    /// A finished phrase.
    var onPhrase: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private static let chunkBytes = 3_200   // 100 ms
    private var pipeline: SpeechStream?
    private var finishTimer: Timer?
    private var phrases = 0

    var isOn: Bool { pipeline != nil }

    func start(engine: SpeechEngine) {
        if finishTimer != nil { complete() }
        guard pipeline == nil else { return }
        guard let apiKey = Keychain.read(engine.keyAccount) else {
            return fail("Add a \(engine.name) API key on the Mac: Longarm menu → \(engine.name) API Key…")
        }
        let pipeline = SpeechStream()
        pipeline.transcriber = engine.makeTranscriber(apiKey: apiKey) { [weak self, weak pipeline] event in
            guard let self, let pipeline, pipeline === self.pipeline else { return }
            self.handle(event)
        }
        phrases = 0
        self.pipeline = pipeline
        pipeline.transcriber?.start()
        DebugLog.write("phone dictation start engine=\(engine.rawValue)")
    }

    /// Microphone audio from the phone, already 16 kHz mono PCM16.
    func audio(_ pcm: Data) {
        pipeline?.append(pcm, chunkBytes: Self.chunkBytes)
    }

    /// Stops listening; words still being recognised are typed before it wraps up.
    func finish() {
        guard let pipeline, finishTimer == nil else { return }
        pipeline.flush()
        let finalizing = pipeline.transcriber?.finalize() ?? false
        finishTimer = Timer.scheduledTimer(withTimeInterval: finalizing ? 2 : 1, repeats: false) { [weak self] _ in
            self?.complete()
        }
    }

    func cancel() {
        guard let pipeline else { return }
        finishTimer?.invalidate()
        finishTimer = nil
        self.pipeline = nil
        pipeline.stop()
        onLive?("", true)
    }

    private func complete() {
        guard let pipeline else { return }
        finishTimer?.invalidate()
        finishTimer = nil
        self.pipeline = nil
        pipeline.stop()
        DebugLog.write("phone dictation done phrases=\(phrases) KB=\(pipeline.bytesIn / 1024)")
        onLive?("", true)
    }

    private func handle(_ event: TranscriberEvent) {
        switch event {
        case .text(let text, let interim):
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if interim {
                onLive?(words, false)
            } else if !words.isEmpty {
                onPhrase?(words)
                phrases += 1
                onLive?("", false)
            }
        case .finalized:
            if finishTimer != nil { complete() }
        case .failed(let message, let fatal):
            DebugLog.write("phone dictation \(fatal ? "failed" : "dropped"): \(message)")
            if fatal {
                fail(message)
                complete()
            }
        case .endOfTurn, .modelOutput, .connected:
            break
        }
    }

    private func fail(_ message: String) {
        onError?(message)
    }
}
