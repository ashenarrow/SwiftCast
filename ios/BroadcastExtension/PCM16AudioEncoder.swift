import AVFoundation
import CoreMedia
import Foundation

struct EncodedAudioPacket {
    var streamId: UInt16
    var frameId: UInt32
    var timestampUs: UInt64
    var payload: Data
}

final class PCM16AudioEncoder {
    private var frameId: UInt32 = 0

    func encode(sampleBuffer: CMSampleBuffer, streamId: UInt16) -> EncodedAudioPacket? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            return nil
        }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let payload = convertToStereoPCM16(audioBufferList: audioBufferList, asbd: asbd.pointee)
        guard !payload.isEmpty else { return nil }

        frameId &+= 1
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return EncodedAudioPacket(
            streamId: streamId,
            frameId: frameId,
            timestampUs: UInt64(max(0.0, CMTimeGetSeconds(pts) * 1_000_000)),
            payload: payload
        )
    }

    private func convertToStereoPCM16(audioBufferList: AudioBufferList, asbd: AudioStreamBasicDescription) -> Data {
        guard let source = audioBufferList.mBuffers.mData else { return Data() }
        let byteCount = Int(audioBufferList.mBuffers.mDataByteSize)
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let bytesPerSample = max(1, Int(asbd.mBitsPerChannel / 8))
        let sampleCount = byteCount / bytesPerSample

        var output = Data(capacity: (sampleCount / channels) * 2 * MemoryLayout<Int16>.size)
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let floats = source.bindMemory(to: Float.self, capacity: sampleCount)
            for frame in stride(from: 0, to: sampleCount, by: channels) {
                let left = clampPCM16(floats[frame])
                let right = channels > 1 ? clampPCM16(floats[frame + 1]) : left
                output.appendInt16LittleEndian(left)
                output.appendInt16LittleEndian(right)
            }
        } else if bytesPerSample == 2 {
            let samples = source.bindMemory(to: Int16.self, capacity: sampleCount)
            for frame in stride(from: 0, to: sampleCount, by: channels) {
                let left = samples[frame]
                let right = channels > 1 ? samples[frame + 1] : left
                output.appendInt16LittleEndian(left)
                output.appendInt16LittleEndian(right)
            }
        }
        return output
    }

    private func clampPCM16(_ sample: Float) -> Int16 {
        Int16(max(Float(Int16.min), min(Float(Int16.max), sample * 32767)))
    }
}

private extension Data {
    mutating func appendInt16LittleEndian(_ value: Int16) {
        let unsigned = UInt16(bitPattern: value)
        append(UInt8(unsigned & 0xff))
        append(UInt8((unsigned >> 8) & 0xff))
    }
}

