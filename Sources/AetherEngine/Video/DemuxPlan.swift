import Foundation

/// Serializable snapshot of the per-file derived state `HLSVideoEngine`
/// computes during a VOD open — the segment plan (from the container's
/// keyframe index), the first-keyframe anchor, and the rebuilt HEVC
/// extradata when the source needed it. All of it is deterministic for a
/// given file's bytes, so a host can persist the plan (keyed by its own
/// notion of file identity, e.g. infoHash + file index) and hand it back
/// on replay/resume via `load(demuxPlan:)`. A validated plan lets the
/// engine skip the cue-prewarm seek (one or two HTTP Range reads against
/// the file tail), the segment-plan construction, and the in-band
/// parameter-set scan — shaving real round-trips off every resume.
///
/// Validation is the engine's job, not the host's: a plan is used only
/// when `fileSize` matches the byte size the open's Range probe reports
/// AND the container duration agrees. An RD link that now serves
/// different bytes under the same key fails the size check and the load
/// silently falls back to a full open — a stale plan can never produce a
/// wrong-timeline playback, only a slower-than-cached one.
public struct DemuxPlan: Codable, Equatable, Sendable {
    public struct PlanSegment: Codable, Equatable, Sendable {
        /// Boundaries in the source video stream's time base (the time
        /// base travels with the file, so it needs no separate field).
        public let startPts: Int64
        public let endPts: Int64
        public let startSeconds: Double
        public let durationSeconds: Double

        public init(startPts: Int64, endPts: Int64,
                    startSeconds: Double, durationSeconds: Double) {
            self.startPts = startPts
            self.endPts = endPts
            self.startSeconds = startSeconds
            self.durationSeconds = durationSeconds
        }
    }

    /// Bump when the shape of the derived state changes; the engine
    /// ignores plans from other versions.
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    /// Total source byte size from the open's Range/HEAD probe — the
    /// primary byte-identity check.
    public let fileSize: Int64
    /// Container duration, cross-checked against the fresh open.
    public let durationSeconds: Double
    public let segments: [PlanSegment]
    public let firstKeyframePts: Int64
    public let firstKeyframeSeconds: Double
    /// Rebuilt hvcC for DV Profile 5 sources whose configuration record
    /// shipped without parameter sets; nil when the source needed none.
    public let hevcExtradataOverride: Data?
    /// Whether `segments` came from real indexed keyframes (vs the
    /// uniform-stride fallback).
    public let keyframeAligned: Bool

    public init(formatVersion: Int = DemuxPlan.currentFormatVersion,
                fileSize: Int64,
                durationSeconds: Double,
                segments: [PlanSegment],
                firstKeyframePts: Int64,
                firstKeyframeSeconds: Double,
                hevcExtradataOverride: Data?,
                keyframeAligned: Bool) {
        self.formatVersion = formatVersion
        self.fileSize = fileSize
        self.durationSeconds = durationSeconds
        self.segments = segments
        self.firstKeyframePts = firstKeyframePts
        self.firstKeyframeSeconds = firstKeyframeSeconds
        self.hevcExtradataOverride = hevcExtradataOverride
        self.keyframeAligned = keyframeAligned
    }
}
