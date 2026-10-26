import CoreMedia
import VideoToolbox

/// Hardware H.264 for the phone's view of the screen, tuned for live use: low-latency rate control, no frame reordering,
/// so each captured frame comes out as soon as it's encoded. Frames are handed over in Annex B form
/// (start codes; key frames carry SPS and PPS first), which Android's decoder takes as is.
/// `light` is for a thin link, like a phone on mobile data (see `ScreenCapture.light`).
final class VideoEncoder {
    static let bitRate = 4_000_000          // average, bits/s: well under what the phone's Wi-Fi carried
    static let peakBytesPerSecond = 700_000  // hard cap, so a burst can't back up the link
    static let lightBitRate = 1_200_000
    static let lightPeakBytesPerSecond = 220_000

    let width: Int
    let height: Int
    let light: Bool
    private let session: VTCompressionSession

    init?(width: Int, height: Int, light: Bool) {
        self.width = width
        self.height = height
        self.light = light
        let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: specification,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            DebugLog.write("video encoder: couldn't create (\(status))")
            return nil
        }
        self.session = session
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: light ? Self.lightBitRate : Self.bitRate,
            kVTCompressionPropertyKey_DataRateLimits: [light ? Self.lightPeakBytesPerSecond : Self.peakBytesPerSecond, 1] as CFArray,
            kVTCompressionPropertyKey_ExpectedFrameRate: ScreenCapture.framesPerSecond(light: light),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,   // a lost frame heals within 2 s
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if status != noErr { DebugLog.write("video encoder: \(key) not set (\(status))") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Encodes [pixels]; [done] gets the Annex B bytes and whether it's a key frame, on the encoder's thread.
    func encode(_ pixels: CVPixelBuffer, keyFrame: Bool, done: @escaping (Data, Bool) -> Void) {
        let properties = keyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let time = CMClockGetTime(CMClockGetHostTimeClock())   // re-sent frames need fresh times too
        let submitted = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: time, duration: .invalid,
                                                        frameProperties: properties, infoFlagsOut: nil) { status, flags, sample in
            guard status == noErr, let sample, let frame = Self.annexB(sample) else {
                DebugLog.write("video encoder: frame failed (\(status), flags \(flags.rawValue), sample \(sample != nil))")
                return
            }
            done(frame.data, frame.keyFrame)
        }
        if submitted != noErr { DebugLog.write("video encoder: couldn't submit a frame (\(submitted))") }
    }

    private static func annexB(_ sample: CMSampleBuffer) -> (data: Data, keyFrame: Bool)? {
        let startCode: [UInt8] = [0, 0, 0, 1]
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyFrame = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var out = Data()
        if keyFrame, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
                guard let pointer else { return nil }
                out.append(contentsOf: startCode)
                out.append(pointer, count: size)
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { return nil }
        // VideoToolbox writes each NAL unit with a 4-byte big-endian length; Annex B wants a start code instead.
        var offset = 0
        while offset + 4 <= length {
            let size = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            guard offset + 4 + size <= length else { return nil }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[offset + 4..<offset + 4 + size])
            offset += 4 + size
        }
        return (out, keyFrame)
    }
}
