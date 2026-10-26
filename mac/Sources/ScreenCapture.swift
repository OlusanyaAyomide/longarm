import AppKit
import ScreenCaptureKit

/// Captures a screen region with ScreenCaptureKit and streams it to the phone as H.264
/// (`VideoEncoder`). Frames are only encoded and sent while a region is shown. ScreenCaptureKit
/// only delivers a frame when something in the region changes, so a still screen costs next to
/// nothing; once it goes still, the last frame is sent again a few times so the encoder can
/// sharpen it. While `light`, it sends fewer, smaller, more compressed frames, for a thin link.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    static func framesPerSecond(light: Bool) -> Int32 { light ? 30 : 60 }
    static func longestSide(light: Bool) -> CGFloat { light ? 1440 : 2400 }   // pixels; Retina detail up to about a phone screen's
    static let sharpenDelay: TimeInterval = 0.25
    static let sharpenTimes = 3

    /// A frame for the phone and whether it's a key frame (see `LinkServer.broadcastFrame`), on the main queue.
    var onFrame: ((Data, Bool) -> Void)?
    /// Each captured frame while one is shown, unencoded, on the capture queue: for WebRTC
    /// (`InternetLink`), which encodes for itself.
    var onPixels: ((CVPixelBuffer) -> Void)?
    /// Whether to encode frames for `onFrame` (only home phones use them). Set on the main queue.
    var encodesFrames = true
    /// Something the owner should know (no permission, capture failed), or nil once it works.
    var onProblem: ((String?) -> Void)?
    private(set) var problem: String?
    /// The phone is on a thin link (mobile data, see `RemoteControl`).
    private(set) var light = false

    private var running = false
    private var target: ScreenRegion?             // what the stream should capture
    private var shown: UInt32?                // the generation the phone is showing, if any
    private var stream: SCStream?
    private var streamArea: ScreenRegion?         // what the stream does capture
    private var streamDisplay: CGDirectDisplayID?
    private var configuring = false

    // Touched on `queue` only.
    private let queue = DispatchQueue(label: "longarm.screen-capture")
    private var encoder: VideoEncoder?
    private var latest: CVPixelBuffer?
    private var sending: UInt32?
    private var expected = (width: 0, height: 0, light: false)
    private var keyFrameNext = true
    private var captured = 0                  // frames from the screen so far, to spot when it goes still
    private var sharpened = 0
    private var stats = (since: Date(), captured: 0, encoded: 0, keyFrames: 0, encodeTime: 0.0, bytes: 0)

    // MARK: - Main queue

    func start() {
        guard !running else { return }
        running = true
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()   // asks once; after that it only says no
            report("Allow Screen Recording for Longarm in System Settings → Privacy & Security, then quit and reopen Longarm")
            return
        }
        sync()
    }

    /// The phone (re)started its decoder, or a frame had to be dropped: start again from a key frame.
    func requestKeyFrame() {
        queue.async {
            self.keyFrameNext = true
            if self.sending != nil, let latest = self.latest { self.encode(latest) }
        }
    }

    var isCapturing: Bool { stream != nil }

    /// [done] runs (on the main queue) once ScreenCaptureKit has let go of the screen. Quitting
    /// without waiting for that leaves macOS showing Longarm as still sharing.
    func stop(done: (() -> Void)? = nil) {
        running = false
        shown = nil
        problem = nil   // said again if it still applies next time
        stopStream(done: done)
    }

    func setLight(_ on: Bool) {
        guard on != light else { return }
        DebugLog.write("screen capture: \(on ? "light, for a thin link" : "full quality")")
        light = on
        streamArea = nil   // reconfigure, even for the same area
        sync()
    }

    /// Shows [area] on the phone, tagged with [generation], or nothing.
    func show(_ area: ScreenRegion?, generation: UInt32) {
        if let area { target = area }
        shown = area == nil ? nil : generation
        sync()
    }

    /// Brings the stream in line with `target` and `shown`, one reconfiguration at a time.
    private func sync() {
        guard running, !configuring, let target, CGPreflightScreenCaptureAccess() else {
            if shown == nil { queue.async { self.sending = nil } }
            return
        }
        if stream != nil, streamArea?.rect == target.rect, streamArea?.display == target.display {
            let shown = self.shown
            queue.async {
                guard shown != self.sending else { return }
                self.sending = shown
                self.keyFrameNext = true
                if shown != nil, let latest = self.latest { self.encode(latest) }
            }
            return
        }
        configuring = true
        aim(at: target) { [weak self] in
            guard let self else { return }
            self.configuring = false
            self.sync()
        }
    }

    private func aim(at area: ScreenRegion, then done: @escaping () -> Void) {
        guard let screen = area.screen, let displayID = screen.displayID else {
            report("The display for \(area.name) isn't connected")
            return done()
        }
        let light = self.light
        let config = Self.configuration(for: area, scale: screen.backingScaleFactor, light: light)
        queue.async {
            self.sending = nil
            self.latest = nil
            self.expected = (config.width, config.height, light)
        }
        if let stream, streamDisplay == displayID {
            stream.updateConfiguration(config) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error { self.report("Couldn't capture \(area.name): \(error.localizedDescription)") } else { self.streamArea = area }
                    done()
                }
            }
            return
        }
        stopStream()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.running else { return done() }
                guard let display = content?.displays.first(where: { $0.displayID == displayID }) else {
                    self.report("Couldn't capture the screen: \(error?.localizedDescription ?? "display not found")")
                    return done()
                }
                let ownApp = content?.applications.filter { $0.processID == getpid() } ?? []
                let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                } catch {
                    self.report("Couldn't capture the screen: \(error.localizedDescription)")
                    return done()
                }
                self.stream = stream
                self.streamDisplay = displayID
                stream.startCapture { error in
                    DispatchQueue.main.async {
                        if let error {
                            self.stopStream()
                            self.report("Couldn't capture the screen: \(error.localizedDescription)")
                        } else {
                            self.streamArea = area
                            self.report(nil)
                            DebugLog.write("screen capture started on display \(displayID)")
                        }
                        done()
                    }
                }
            }
        }
    }

    private func stopStream(done: (() -> Void)? = nil) {
        if let stream {
            stream.stopCapture { _ in DispatchQueue.main.async { done?() } }
        } else if let done {
            DispatchQueue.main.async(execute: done)
        }
        stream = nil
        streamArea = nil
        streamDisplay = nil
        queue.async {
            self.sending = nil
            self.latest = nil
            self.encoder = nil
        }
    }

    private func report(_ problem: String?) {
        guard problem != self.problem else { return }
        self.problem = problem
        if let problem { DebugLog.write("screen capture: \(problem)") }
        onProblem?(problem)
    }

    private static func configuration(for area: ScreenRegion, scale: CGFloat, light: Bool) -> SCStreamConfiguration {
        let scale = min(scale, longestSide(light: light) / max(area.rect.width, area.rect.height, 1))
        let config = SCStreamConfiguration()
        config.sourceRect = area.rect
        config.width = Int((area.rect.width * scale / 2).rounded()) * 2   // even, as H.264 decoders like it
        config.height = Int((area.rect.height * scale / 2).rounded()) * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond(light: light))
        config.showsCursor = true   // so the phone shows what you're pointing at
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 5
        return config
    }

    // MARK: - SCStreamDelegate, SCStreamOutput

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard stream === self.stream else { return }
            self.stream = nil
            self.streamArea = nil
            self.streamDisplay = nil
            self.report("Screen capture stopped: \(error.localizedDescription)")
            // Try once more shortly (e.g. after the display slept); `sync` rebuilds the stream.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.sync() }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let status = (info[.status] as? Int).flatMap(SCFrameStatus.init), status == .complete,
              let pixels = sampleBuffer.imageBuffer,
              CVPixelBufferGetWidth(pixels) == expected.width, CVPixelBufferGetHeight(pixels) == expected.height
        else { return }   // idle frames (nothing changed), and leftovers from before a re-aim
        latest = pixels
        captured += 1
        sharpened = 0
        stats.captured += 1
        if sending != nil {
            onPixels?(pixels)
            if encodesFrames { encode(pixels) }
        }
        logStats()
    }

    /// Every 5 s while frames flow: how many came in and went out, encode time and size.
    private func logStats() {
        let elapsed = Date().timeIntervalSince(stats.since)
        guard elapsed >= 5 else { return }
        if stats.captured > 0 {
            DebugLog.write(String(format: "video frames: %.1f/s captured, %.1f/s encoded (%d key), %.0f ms to encode, %.1f KB each, %dx%d",
                                  Double(stats.captured) / elapsed, Double(stats.encoded) / elapsed, stats.keyFrames,
                                  stats.encoded > 0 ? stats.encodeTime / Double(stats.encoded) * 1000 : 0,
                                  stats.encoded > 0 ? Double(stats.bytes) / Double(stats.encoded) / 1024 : 0, expected.width, expected.height))
        }
        stats = (Date(), 0, 0, 0, 0, 0)
    }

    /// On `queue`. The phone gets 0x02, the generation (UInt32), 1 if a key frame else 0, the width
    /// and height (UInt16 each), then the H.264 frame; all numbers big-endian.
    private func encode(_ pixels: CVPixelBuffer) {
        guard let generation = sending else { return }
        if encoder?.width != expected.width || encoder?.height != expected.height || encoder?.light != expected.light {
            encoder = VideoEncoder(width: expected.width, height: expected.height, light: expected.light)
            keyFrameNext = true
        }
        guard let encoder else { return }
        let keyFrame = keyFrameNext
        keyFrameNext = false
        let started = Date()
        let (width, height) = (UInt16(expected.width), UInt16(expected.height))
        encoder.encode(pixels, keyFrame: keyFrame) { [weak self] data, isKey in
            var frame = Data([2])
            withUnsafeBytes(of: generation.bigEndian) { frame.append(contentsOf: $0) }
            frame.append(isKey ? 1 : 0)
            withUnsafeBytes(of: width.bigEndian) { frame.append(contentsOf: $0) }
            withUnsafeBytes(of: height.bigEndian) { frame.append(contentsOf: $0) }
            frame.append(data)
            self?.queue.async {
                guard let self else { return }
                self.stats.encoded += 1
                self.stats.keyFrames += isKey ? 1 : 0
                self.stats.encodeTime += Date().timeIntervalSince(started)
                self.stats.bytes += frame.count
            }
            DispatchQueue.main.async { self?.onFrame?(frame, isKey) }
        }
        sharpenWhenStill()
    }

    /// When no new frame follows, sends the last one again a few times: the encoder spends what's
    /// left of its budget refining it, so text that just stopped moving turns crisp.
    private func sharpenWhenStill() {
        let frame = captured
        queue.asyncAfter(deadline: .now() + Self.sharpenDelay) { [weak self] in
            guard let self, self.captured == frame, self.sharpened < Self.sharpenTimes,
                  self.sending != nil, let latest = self.latest else { return }
            self.sharpened += 1
            self.encode(latest)
        }
    }
}
