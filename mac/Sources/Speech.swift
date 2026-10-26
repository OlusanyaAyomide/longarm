import Foundation

/// The speech-to-text service dictation from the phone goes through. One for now; another is a
/// `StreamingTranscriber` subclass plus a case here.
enum SpeechEngine: String, CaseIterable {
    case deepgram

    var name: String { "Deepgram" }
    var keyAccount: String { "deepgram-api-key" }   // its API key in the Keychain
    var keyPage: String { "https://console.deepgram.com" }

    func makeTranscriber(apiKey: String, onEvent: @escaping (TranscriberEvent) -> Void) -> StreamingTranscriber {
        let defaults = UserDefaults.standard
        return DeepgramTranscriber(apiKey: apiKey,
                                   model: defaults.string(forKey: "deepgramModel") ?? "nova-3",
                                   language: defaults.string(forKey: "deepgramLanguage") ?? "en",
                                   onEvent: onEvent)
    }
}

/// 16 kHz mono 16-bit PCM on its way to a transcriber, sent in fixed-size chunks.
final class SpeechStream {
    var transcriber: StreamingTranscriber?
    private(set) var bytesIn = 0
    private var chunk = Data()

    func append(_ pcm: Data, chunkBytes: Int) {
        bytesIn += pcm.count
        chunk.append(pcm)
        guard chunk.count >= chunkBytes else { return }
        transcriber?.send(chunk)
        chunk = Data()
    }

    /// Sends what's left of the last chunk.
    func flush() {
        guard !chunk.isEmpty else { return }
        transcriber?.send(chunk)
        chunk = Data()
    }

    func stop() {
        transcriber?.stop()
    }
}
