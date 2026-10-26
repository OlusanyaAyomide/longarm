import Foundation

/// Plain-text diagnostics at ~/Library/Logs/Longarm/longarm.log, started fresh on each launch.
/// Records what the transcription path is doing (levels, bytes, connection events), never the
/// words themselves or the API key.
enum DebugLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Longarm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("longarm.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)   // truncate on launch
        return url
    }()

    private static let queue = DispatchQueue(label: "longarm.debug-log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ line: String) {
        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        queue.async {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        }
    }
}
