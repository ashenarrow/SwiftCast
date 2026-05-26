import Foundation
import CoreGraphics

enum SwiftCastPreset: String, Codable, CaseIterable {
    case gaming
    case hotspot
    case battery
    case custom
}

enum SwiftCastROIMode: String, Codable, CaseIterable {
    case off
    case manual
    case motion
    case touch
    case center
}

enum SwiftCastLatencyMode: String, Codable {
    case gaming
    case balanced
}

struct SwiftCastSettings: Codable, Equatable {
    var preset: SwiftCastPreset = .gaming
    var width: Int = 1280
    var height: Int = 720
    var fps: Int = 30
    var dynamicBitrateEnabled: Bool = true
    var minBitrateKbps: Int = 3000
    var maxBitrateKbps: Int = 8000
    var congestionAggressiveness: Double = 0.72
    var temporalCompressionEnabled: Bool = true
    var pFramesEnabled: Bool = true
    var keyframeIntervalMs: Int = 1000
    var roiEnabled: Bool = false
    var roiMode: SwiftCastROIMode = .off
    var roiRect: CGRectCodable = .init(x: 0.35, y: 0.30, width: 0.30, height: 0.30)
    var appAudioEnabled: Bool = true
    var micAudioEnabled: Bool = false
    var appAudioGain: Double = 1
    var micGain: Double = 1
    var audioSyncOffsetMs: Int = 0
    var latencyMode: SwiftCastLatencyMode = .gaming

    static let `default` = SwiftCastSettings()
}

struct CGRectCodable: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct SessionInfo: Codable {
    var pairCode: String
    var settings: SwiftCastSettings
}

struct IceCandidateRecord: Codable {
    var candidate: String
    var sdpMLineIndex: Int32
    var sdpMid: String?
}
