import Foundation

/// What a speech-to-text stream reports back.
enum TranscriberEvent {
    /// Words heard. Interim text is a guess that the next text event replaces; final text is kept.
    case text(String, interim: Bool)
    case endOfTurn                 // the speaker paused; the current line is finished
    case finalized                 // everything sent so far is now final text (answer to finalize())
    case modelOutput               // a model-based service replied instead of transcribing (diagnostics)
    case connected
    case failed(String, fatal: Bool)
}

/// A WebSocket that streams 16 kHz mono 16-bit PCM to a speech-to-text service, buffering audio
/// while it (re)connects and reconnecting on its own. Subclasses say how to connect, how audio is
/// framed and how to read what comes back. Everything runs on the main queue.
class StreamingTranscriber: NSObject, URLSessionWebSocketDelegate {
    let name: String
    let onEvent: (TranscriberEvent) -> Void

    private static let maxBufferedChunks = 100   // ~10 s of audio while (re)connecting
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var running = false
    private var ready = false
    private var pending: [Data] = []
    private var retryDelay: TimeInterval = 1

    init(name: String, onEvent: @escaping (TranscriberEvent) -> Void) {
        self.name = name
        self.onEvent = onEvent
    }

    // MARK: - For subclasses

    func makeRequest() -> URLRequest { fatalError("subclass must override") }

    /// The socket is open. Call `markReady()` once audio may flow (now, or after a setup reply).
    func socketDidOpen() { markReady() }

    func audioMessage(_ pcm: Data) -> URLSessionWebSocketTask.Message { .data(pcm) }

    func handle(_ data: Data) {}

    /// A failure that retrying can't fix, such as a rejected key or request.
    func isFatal(code: URLSessionWebSocketTask.CloseCode, httpStatus: Int?) -> Bool { false }

    /// Last words before an intentional close.
    func willStop() {}

    /// Asks the service to turn everything it has heard into final text now (end of dictation).
    /// Returns false if it can't, in which case the caller just waits briefly.
    func finalize() -> Bool { false }

    final func markReady() {
        ready = true
        retryDelay = 1
        let buffered = pending
        pending.removeAll()
        buffered.forEach(send)
        onEvent(.connected)
    }

    final func sendJSON(_ object: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    /// Swap to a fresh connection now, e.g. when the service warns it's about to close this one.
    final func reconnectNow() {
        guard running else { return }
        disconnect()
        connect()
    }

    // MARK: - Use

    func start() {
        running = true
        connect()
    }

    func stop() {
        if ready { willStop() }
        running = false
        disconnect()
        pending.removeAll()
    }

    func send(_ pcm: Data) {
        guard running else { return }
        guard ready, let task else {
            pending.append(pcm)
            if pending.count > Self.maxBufferedChunks { pending.removeFirst() }
            return
        }
        task.send(audioMessage(pcm)) { _ in }
    }

    // MARK: - Connection

    private func connect() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: makeRequest())
        task.maximumMessageSize = 16 * 1024 * 1024
        self.session = session
        self.task = task
        ready = false
        task.resume()
        receive(on: task)
    }

    private func disconnect() {
        ready = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        DebugLog.write("\(name) socket open")
        socketDidOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        connectionLost(text.isEmpty ? "Connection closed (\(closeCode.rawValue))" : text, task: webSocketTask)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, task === self.task else { return }
            switch result {
            case .success(.string(let text)): self.handle(Data(text.utf8))
            case .success(.data(let data)): self.handle(data)
            case .success: break
            case .failure(let error): return self.connectionLost(error.localizedDescription, task: task)
            }
            self.receive(on: task)
        }
    }

    private func connectionLost(_ reason: String, task: URLSessionWebSocketTask) {
        guard running else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        DebugLog.write("\(name) closed code=\(task.closeCode.rawValue) http=\(status.map(String.init) ?? "-"): \(reason)")
        disconnect()
        if isFatal(code: task.closeCode, httpStatus: status) {
            running = false
            let message = status == 401 || status == 403 ? "The API key was rejected" : reason
            return onEvent(.failed(message, fatal: true))
        }
        onEvent(.failed(reason, fatal: false))
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self, self.running, self.task == nil else { return }
            self.connect()
        }
        retryDelay = min(retryDelay * 2, 10)
    }
}
