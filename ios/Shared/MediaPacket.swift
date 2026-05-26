import Foundation

enum SwiftCastPacketType: UInt8 {
    case video = 1
    case audio = 2
}

struct SwiftCastPacketFlags: OptionSet {
    let rawValue: UInt8
    static let keyframe = SwiftCastPacketFlags(rawValue: 1 << 0)
    static let config = SwiftCastPacketFlags(rawValue: 1 << 1)
    static let roi = SwiftCastPacketFlags(rawValue: 1 << 2)
}

enum MediaPacketWriter {
    static let magic: UInt16 = 0x5343
    static let version: UInt8 = 1
    static let headerLength: UInt8 = 32
    static let maxPayloadBytes = 12 * 1024

    static func packets(
        type: SwiftCastPacketType,
        streamId: UInt16,
        frameId: UInt32,
        timestampUs: UInt64,
        flags: SwiftCastPacketFlags,
        configVersion: UInt16,
        payload: Data
    ) -> [Data] {
        let chunkCount = max(1, Int(ceil(Double(payload.count) / Double(maxPayloadBytes))))
        return (0..<chunkCount).map { index in
            let start = index * maxPayloadBytes
            let end = min(payload.count, start + maxPayloadBytes)
            let chunk = payload.subdata(in: start..<end)
            var data = Data(capacity: Int(headerLength) + chunk.count)
            data.appendUInt16(magic)
            data.append(version)
            data.append(type.rawValue)
            data.append(flags.rawValue)
            data.append(headerLength)
            data.appendUInt16(streamId)
            data.appendUInt32(frameId)
            data.appendUInt64(timestampUs)
            data.appendUInt16(UInt16(index))
            data.appendUInt16(UInt16(chunkCount))
            data.appendUInt16(configVersion)
            data.appendUInt16(0)
            data.appendUInt32(UInt32(chunk.count))
            data.append(chunk)
            return data
        }
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt64(_ value: UInt64) {
        appendUInt32(UInt32((value >> 32) & 0xffffffff))
        appendUInt32(UInt32(value & 0xffffffff))
    }
}

