import CoreImage
import CoreMedia
import Foundation
import VideoToolbox

struct EncodedVideoFrame {
    var frameId: UInt32
    var timestampUs: UInt64
    var isKeyframe: Bool
    var configVersion: UInt16
    var payload: Data
}

final class H264Encoder {
    private var settings: SwiftCastSettings
    private let output: (EncodedVideoFrame) -> Void
    private var session: VTCompressionSession?
    private var frameId: UInt32 = 0
    private var configVersion: UInt16 = 1
    private var sps = Data()
    private var pps = Data()
    private let encodeQueue = DispatchQueue(label: "swiftcast.h264.encoder")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var pixelBufferPool: CVPixelBufferPool?

    init(settings: SwiftCastSettings, output: @escaping (EncodedVideoFrame) -> Void) {
        self.settings = settings
        self.output = output
    }

    func update(settings: SwiftCastSettings) {
        encodeQueue.async {
            let bitrateChanged = self.settings.maxBitrateKbps != settings.maxBitrateKbps
            let keyframeChanged = self.settings.keyframeIntervalMs != settings.keyframeIntervalMs
            self.settings = settings
            if bitrateChanged || keyframeChanged {
                self.applyMutableProperties()
            }
        }
    }

    func encode(sampleBuffer: CMSampleBuffer, forceKeyframe: Bool) {
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encodeQueue.async {
            do {
                try self.ensureSession()
                guard let session = self.session else { return }
                let pixelBuffer = self.scaledPixelBuffer(from: source) ?? source
                var options: CFDictionary?
                if forceKeyframe {
                    options = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
                }
                VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid, frameProperties: options, sourceFrameRefcon: nil, infoFlagsOut: nil)
            } catch {
                self.invalidateOnQueue()
            }
        }
    }

    func invalidate() {
        encodeQueue.async {
            self.invalidateOnQueue()
        }
    }

    private func invalidateOnQueue() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        pixelBufferPool = nil
    }

    private func ensureSession() throws {
        guard session == nil else { return }

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(settings.width),
            height: Int32(settings.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: Self.hardwareEncoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: H264Encoder.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else { throw NSError(domain: "SwiftCast.H264", code: Int(status)) }

        session = newSession
        applyMutableProperties()
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: settings.temporalCompressionEnabled ? kCFBooleanTrue : kCFBooleanFalse)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: settings.fps))
        VTCompressionSessionPrepareToEncodeFrames(newSession)
        makePixelBufferPool()
    }

    private static var hardwareEncoderSpecification: CFDictionary {
        var specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ]

        if #available(iOS 17.4, *) {
            specification[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = kCFBooleanTrue as Any
            specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = kCFBooleanTrue as Any
        } else {
            specification["EnableHardwareAcceleratedVideoEncoder" as CFString] = kCFBooleanTrue as Any
            specification["RequireHardwareAcceleratedVideoEncoder" as CFString] = kCFBooleanTrue as Any
        }

        return specification as CFDictionary
    }

    private func applyMutableProperties() {
        guard let session else { return }
        let bitrate = settings.dynamicBitrateEnabled ? settings.maxBitrateKbps * 1000 : settings.minBitrateKbps * 1000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [NSNumber(value: bitrate / 8), NSNumber(value: 1)] as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: Double(settings.keyframeIntervalMs) / 1000.0))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: max(1, settings.fps * settings.keyframeIntervalMs / 1000)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: settings.temporalCompressionEnabled && settings.pFramesEnabled ? kCFBooleanTrue : kCFBooleanFalse)
    }

    private func makePixelBufferPool() {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: settings.width,
            kCVPixelBufferHeightKey as String: settings.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pixelBufferPool)
    }

    private func scaledPixelBuffer(from source: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetWidth(source) != settings.width || CVPixelBufferGetHeight(source) != settings.height,
              let pixelBufferPool else {
            return source
        }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &output)
        guard let output else { return nil }

        let image = CIImage(cvPixelBuffer: source)
        let scaleX = CGFloat(settings.width) / image.extent.width
        let scaleY = CGFloat(settings.height) / image.extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(scaled, to: output)
        return output
    }

    private func handle(sampleBuffer: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil
        if isKeyframe {
            updateParameterSets(from: sampleBuffer)
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let annexB = makeAnnexB(from: blockBuffer, includeParameterSets: isKeyframe) else {
            return
        }

        frameId &+= 1
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        output(EncodedVideoFrame(
            frameId: frameId,
            timestampUs: UInt64(max(0.0, CMTimeGetSeconds(pts) * 1_000_000)),
            isKeyframe: isKeyframe,
            configVersion: configVersion,
            payload: annexB
        ))
    }

    private func updateParameterSets(from sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        var parameterSetCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
        guard parameterSetCount >= 2 else { return }

        sps = parameterSet(format: format, index: 0)
        pps = parameterSet(format: format, index: 1)
        configVersion &+= 1
    }

    private func parameterSet(format: CMFormatDescription, index: Int) -> Data {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        guard let pointer, size > 0 else { return Data() }
        return Data(bytes: pointer, count: size)
    }

    private func makeAnnexB(from blockBuffer: CMBlockBuffer, includeParameterSets: Bool) -> Data? {
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer else { return nil }

        var output = Data()
        if includeParameterSets {
            appendStartCode(to: &output, nal: sps)
            appendStartCode(to: &output, nal: pps)
        }

        var offset = 0
        while offset + 4 <= length {
            let nalLength = dataPointer.advanced(by: offset).withMemoryRebound(to: UInt8.self, capacity: 4) { ptr -> Int in
                (Int(ptr[0]) << 24) | (Int(ptr[1]) << 16) | (Int(ptr[2]) << 8) | Int(ptr[3])
            }
            offset += 4
            guard nalLength > 0, offset + nalLength <= length else { break }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(Data(bytes: dataPointer.advanced(by: offset), count: nalLength))
            offset += nalLength
        }
        return output
    }

    private func appendStartCode(to data: inout Data, nal: Data) {
        guard !nal.isEmpty else { return }
        data.append(contentsOf: [0, 0, 0, 1])
        data.append(nal)
    }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard status == noErr,
              let refcon,
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.handle(sampleBuffer: sampleBuffer)
    }
}
