import Foundation

/// Deepgram streaming speech-to-text (Nova-3). Words arrive while they're being spoken as interim
/// results, each replaced by the next, then firm up as final text; `speech_final` marks a pause.
final class DeepgramTranscriber: StreamingTranscriber {
    private static let endpoint = "wss://api.deepgram.com/v1/listen"

    private let apiKey: String
    private let model: String
    private let language: String

    init(apiKey: String, model: String, language: String, onEvent: @escaping (TranscriberEvent) -> Void) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        super.init(name: "deepgram", onEvent: onEvent)
    }

    override func makeRequest() -> URLRequest {
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "endpointing", value: "300"),        // ms of silence that ends a sentence
            URLQueryItem(name: "utterance_end_ms", value: "1000"),  // fallback when noise hides the pause
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    // A bad key or request is refused at the handshake; retrying won't change that.
    override func isFatal(code: URLSessionWebSocketTask.CloseCode, httpStatus: Int?) -> Bool {
        guard let httpStatus else { return false }
        return (400..<500).contains(httpStatus) && httpStatus != 429
    }

    /// Asks Deepgram to finish what it has heard before the socket closes.
    override func willStop() {
        sendJSON(["type": "CloseStream"])
    }

    override func finalize() -> Bool {
        sendJSON(["type": "Finalize"])
        return true
    }

    override func handle(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch message["type"] as? String {
        case "Results":
            let alternative = ((message["channel"] as? [String: Any])?["alternatives"] as? [[String: Any]])?.first
            let transcript = alternative?["transcript"] as? String ?? ""
            let isFinal = message["is_final"] as? Bool ?? false
            if !transcript.isEmpty || isFinal { onEvent(.text(transcript, interim: !isFinal)) }
            if message["from_finalize"] as? Bool == true { onEvent(.finalized) }
            if message["speech_final"] as? Bool == true { onEvent(.endOfTurn) }
        case "UtteranceEnd":
            onEvent(.endOfTurn)
        case let type?:
            DebugLog.write("deepgram message \(type)")
        default:
            break
        }
    }
}
