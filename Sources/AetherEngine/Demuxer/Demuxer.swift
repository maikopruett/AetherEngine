import Foundation
import Libavformat
import Libavcodec
import Libavutil


/// Open-time tuning for the demuxer + its AVIO reader. `.playback` is
/// the default everywhere; `.stillExtraction` switches AVIO to a
/// random-access profile (no read-ahead prefetch, small seek chunk) and
/// a minimal probe budget for fast single-keyframe fetches.
struct DemuxerOpenProfile: Sendable {
    var probesize: Int64
    var maxAnalyzeDuration: Int64
    var avioPrefetch: Bool
    var avioChunkSize: Int
    /// URL opens try `.fastProbe` first and only re-open with this full
    /// profile when the fast pass left a playable stream without codec
    /// parameters (see `hasPlayableStreamMissingParameters`).
    var fastFirstPass: Bool = false

    static let playback = DemuxerOpenProfile(
        probesize: 50 * 1024 * 1024,
        maxAnalyzeDuration: 60 * 1_000_000,
        avioPrefetch: true,
        avioChunkSize: 4 * 1024 * 1024,
        fastFirstPass: true
    )

    /// First pass for `.playback` URL opens. Sizing logic: well-formed
    /// MP4/MKV files carry codec parameters in their headers, so
    /// find_stream_info exits long before ANY budget — the budget is
    /// only ever spent in full on streams that can't parameterize, which
    /// makes probesize the exact per-play cost of a malformed stream
    /// (e.g. broken cover art: 8 MB ≈ 5.7 s at 12 Mbps, measured; 2 MB
    /// ≈ 1.4 s). Files that legitimately need deep probing (sparse
    /// PGS/DVB subtitle tracks, TS containers) escalate to the full
    /// `.playback` budget — one extra open + 2 MB, noise next to the
    /// 50 MB those files read anyway. analyzeDuration stays at 5 s of
    /// content so frame-rate estimation keeps enough material; for
    /// packet-less streams it never binds (probesize does).
    /// avioChunkSize matches `.playback` because the fast-pass reader
    /// stays live for the whole session when no escalation happens.
    static let fastProbe = DemuxerOpenProfile(
        probesize: 2 * 1024 * 1024,
        maxAnalyzeDuration: 5 * 1_000_000,
        avioPrefetch: true,
        avioChunkSize: 4 * 1024 * 1024
    )

    static let stillExtraction = DemuxerOpenProfile(
        probesize: 2 * 1024 * 1024,
        maxAnalyzeDuration: 2 * 1_000_000,
        avioPrefetch: false,
        avioChunkSize: 1 * 1024 * 1024
    )
}

/// FFmpeg AVFormatContext wrapper. Opens a media URL, reads the stream
/// info, and produces demuxed `AVPacket`s for the decoder.
///
/// For HTTP(S) URLs, uses a custom AVIO context backed by URLSession
/// (since FFmpegBuild has no built-in network stack). File URLs are
/// handled directly by FFmpeg's file protocol.
///
/// Thread safety: `readPacket()` and `seek()` are serialized via an
/// internal lock, so `seek()` can safely be called from any thread
/// (e.g. main actor) while the demux loop reads on a background queue.
public final class Demuxer: @unchecked Sendable {
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?

    /// Serializes access to formatContext between readPacket() (demux queue)
    /// and seek() (main actor), prevents concurrent AVFormatContext access
    /// that triggers assertion failures in matroskadec.c.
    private let accessLock = NSLock()

    /// Retained while the format context is open for AVIO-backed sources
    /// (HTTP via AVIOReader, custom via CustomIOReaderBridge).
    private var avioProvider: AVIOProvider?

    /// Sticky record that `markClosed()` was called, so an open that is
    /// still wiring up its AVIO provider (HEAD probe in flight, provider
    /// not yet assigned) observes a concurrent markClosed instead of losing
    /// it to the assignment race and reading to completion. Set only by
    /// `markClosed()` — never by `close()`, whose direct provider unblock
    /// must not poison the fast-probe re-open inside `open()`.
    private var markedClosed = false
    private let markLock = NSLock()

    /// Profile supplied to the most recent `open` call. Governs probe
    /// budget in `applyProbeBudget` and (in a later task) AVIO tuning.
    private var openProfile: DemuxerOpenProfile = .playback

    /// Skip MKV attachment payloads on network opens (default), where
    /// fetching them costs real time; local files read them for free and
    /// keep embedded-font subtitle styling. Tests override to exercise
    /// both paths against local fixtures.
    var skipAttachmentsOverride: Bool?

    private func shouldSkipAttachments(networkSource: Bool) -> Bool {
        skipAttachmentsOverride ?? networkSource
    }

    /// Cumulative bytes fetched by the AVIO reader since the source
    /// was opened. Used by the engine's memory probe to compare
    /// network throughput against RSS growth. Zero for `file://`
    /// sources (no AVIOReader is involved).
    var avioBytesFetched: Int64 {
        avioProvider?.cumulativeBytesFetched ?? 0
    }

    /// Source byte size from the AVIO reader's open-time Range/HEAD
    /// probe. -1 for local files, custom readers, and live sources —
    /// callers treating this as a byte-identity key must require > 0.
    var sourceFileSize: Int64 {
        (avioProvider as? AVIOReader)?.probedFileSize ?? -1
    }

    /// Whether an open succeeded and the format context is live. Callers
    /// adopting a demuxer they didn't open themselves (prewarm handoff)
    /// must check this before trusting its stream table.
    var isOpen: Bool { formatContext != nil }

    /// Whether the opened source supports seeking. Forward-only custom
    /// sources report false; URL sources and unopened demuxers report true.
    var isSourceSeekable: Bool {
        avioProvider?.isSeekable ?? true
    }

    /// Timestamp of the AVIO reader's last unplanned reconnect (drop or
    /// stall, not a seek). Nil for non-HTTP sources or when no drop has
    /// occurred. The live producer correlates this with a backward
    /// source-PTS reset to detect a server that restarted its stream
    /// from the beginning on re-GET (see `AVIOReader.lastUnplannedReconnectAt`).
    var lastUnplannedSourceReconnectAt: Date? {
        (avioProvider as? AVIOReader)?.lastUnplannedReconnectAt
    }

    /// Open a media URL and probe its streams.
    ///
    /// `extraHeaders` are attached to every HTTP request the AVIO
    /// reader issues against `url` (HEAD probe + Range / streaming
    /// GETs). Ignored for `file://` URLs. Pass auth tokens or any
    /// other server-required headers here. Default empty.
    ///
    /// `isLive` marks the source as a genuinely endless live feed and
    /// is forwarded to `AVIOReader` so it suppresses the
    /// `position >= fileSize` EOF synthesis and surfaces a terminal
    /// error when the reconnect cap is hit (instead of collapsing to a
    /// silent EOF). Has no effect on `file://` sources.
    func open(url: URL, extraHeaders: [String: String] = [:], profile: DemuxerOpenProfile = .playback, isLive: Bool = false) throws {
        let start = ContinuousClock.now

        // Two-phase probe for on-demand URL sources: a fast pass covers
        // virtually every file; only a playable stream still missing codec
        // parameters justifies paying for the full-budget re-open. Live
        // feeds skip the fast pass — a re-open means re-GETting a stream
        // whose server may restart it from the beginning.
        if profile.fastFirstPass, !isLive {
            self.openProfile = .fastProbe
            try openByScheme(url: url, extraHeaders: extraHeaders, isLive: isLive)
            guard hasPlayableStreamMissingParameters() else {
                EngineLog.emit("[Demuxer] open+probe took \(Self.elapsedMs(since: start))ms (fast probe, fetched \(Self.mbString(avioBytesFetched))MB)", category: .demux)
                return
            }
            EngineLog.emit("[Demuxer] fast probe left a playable stream without codec parameters after \(Self.elapsedMs(since: start))ms — re-opening with full probe budget", category: .demux)
            close()
        }

        self.openProfile = profile
        try openByScheme(url: url, extraHeaders: extraHeaders, isLive: isLive)
        EngineLog.emit("[Demuxer] open+probe took \(Self.elapsedMs(since: start))ms (full budget, fetched \(Self.mbString(avioBytesFetched))MB)", category: .demux)
    }

    private static func mbString(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    private func openByScheme(url: URL, extraHeaders: [String: String], isLive: Bool) throws {
        let isHTTP = url.scheme == "http" || url.scheme == "https"
        if isHTTP {
            try openHTTP(url: url, extraHeaders: extraHeaders, isLive: isLive)
        } else {
            try openLocal(url: url)
        }
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }

    /// Cover-art image codecs: a "video" stream carrying one of these is
    /// album/poster art, never playable content.
    private static let coverArtCodecIDs: Set<UInt32> = [
        AV_CODEC_ID_PNG.rawValue, AV_CODEC_ID_MJPEG.rawValue, AV_CODEC_ID_BMP.rawValue,
        AV_CODEC_ID_GIF.rawValue, AV_CODEC_ID_TIFF.rawValue, AV_CODEC_ID_WEBP.rawValue,
    ]

    /// True when a stream playback actually consumes (real video, audio,
    /// subtitles) came out of the probe without codec parameters — the
    /// signal that the budget ran out before reaching its packets (sparse
    /// PGS subs in big remuxes) and a deeper probe could still help.
    /// Attached pictures and cover-art video streams can't trigger
    /// escalation: malformed cover art (e.g. MP4 UDTA art that failed atom
    /// parsing, which also loses its ATTACHED_PIC disposition) never gets
    /// parameters no matter how much is read.
    private func hasPlayableStreamMissingParameters() -> Bool {
        guard let ctx = formatContext else { return false }
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let par = stream.pointee.codecpar else { continue }
            if (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0 { continue }
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                if Self.coverArtCodecIDs.contains(par.pointee.codec_id.rawValue) { continue }
                if par.pointee.codec_id == AV_CODEC_ID_NONE || par.pointee.width <= 0 { return true }
            case AVMEDIA_TYPE_AUDIO:
                if par.pointee.codec_id == AV_CODEC_ID_NONE || par.pointee.sample_rate <= 0 { return true }
            case AVMEDIA_TYPE_SUBTITLE:
                if par.pointee.codec_id == AV_CODEC_ID_NONE { return true }
            default:
                continue
            }
        }
        return false
    }

    // MARK: - Open Strategies

    /// Open a local file URL via FFmpeg's built-in file protocol.
    private func openLocal(url: URL) throws {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let allocated = ctx else {
            throw DemuxerError.openFailed(code: -1)
        }
        applyProbeBudget(allocated)

        let urlString = url.isFileURL ? url.path : url.absoluteString
        var opts: OpaquePointer? = nil
        Self.applyDemuxerOptions(&opts, skipAttachments: shouldSkipAttachments(networkSource: false))
        let ret = avformat_open_input(&ctx, urlString, nil, &opts)
        av_dict_free(&opts)
        guard ret == 0, let openedCtx = ctx else {
            throw DemuxerError.openFailed(code: ret)
        }
        formatContext = openedCtx

        try probeStreams(openedCtx)
    }

    /// Open a media source backed by a custom `IOReader` (memory buffer,
    /// encrypted archive, etc.). `formatHint` (e.g. "mp4", "matroska")
    /// disambiguates probing when no filename is available; pass nil to
    /// probe from content only. `isLive` suppresses the duration-estimate
    /// SEEK_END that would latch EOF on a forward-only live reader (same
    /// fix as the URL live path, 38ad60b, now for custom sources).
    func open(reader: IOReader, formatHint: String? = nil, profile: DemuxerOpenProfile = .playback, isLive: Bool = false) throws {
        self.openProfile = profile
        let bridge = CustomIOReaderBridge(reader: reader)
        let inputFormat: UnsafePointer<AVInputFormat>? = formatHint.flatMap { av_find_input_format($0) }
        try openWithProvider(bridge, inputFormat: inputFormat, isLive: isLive)
    }

    /// Open an HTTP(S) URL via custom AVIO context + URLSession.
    private func openHTTP(url: URL, extraHeaders: [String: String], isLive: Bool = false) throws {
        let reader = AVIOReader(
            url: url,
            extraHeaders: extraHeaders,
            chunkSize: openProfile.avioChunkSize,
            prefetchEnabled: openProfile.avioPrefetch,
            isLive: isLive
        )
        try openWithProvider(reader, isLive: isLive,
                             skipAttachments: shouldSkipAttachments(networkSource: true))
    }

    /// Shared open path for AVIO-backed sources. Opens the provider,
    /// attaches its AVIOContext to a fresh AVFormatContext, then runs
    /// avformat_open_input + the stream probe. `inputFormat` forces a
    /// demuxer when non-nil (custom sources with a format hint). `isLive`
    /// suppresses the duration-estimate SEEK_END that would latch EOF on an
    /// unknown-length live source.
    private func openWithProvider(
        _ provider: AVIOProvider,
        inputFormat: UnsafePointer<AVInputFormat>? = nil,
        isLive: Bool = false,
        skipAttachments: Bool = false
    ) throws {
        // 1. Open the provider (HEAD probe for HTTP, alloc context for custom).
        try provider.open()
        avioProvider = provider

        // A markClosed() that raced this assignment found avioProvider nil
        // and couldn't reach the reader — re-deliver it so the abort still
        // kills the open at the first AVIO read.
        markLock.lock()
        let closedWhileOpening = markedClosed
        markLock.unlock()
        if closedWhileOpening { provider.markClosed() }

        // 2. Allocate an empty AVFormatContext and attach the provider's AVIO.
        guard let ctx = avformat_alloc_context() else {
            avioProvider?.close()
            avioProvider = nil
            throw DemuxerError.openFailed(code: -1)
        }
        ctx.pointee.pb = provider.context
        applyProbeBudget(ctx)
        formatContext = ctx

        // 3. Open input, URL is nil because pb is already set.
        var ctxPtr: UnsafeMutablePointer<AVFormatContext>? = ctx
        var opts: OpaquePointer? = nil
        Self.applyDemuxerOptions(&opts, isLive: isLive, skipAttachments: skipAttachments)
        let ret = avformat_open_input(&ctxPtr, nil, inputFormat, &opts)
        av_dict_free(&opts)
        guard ret == 0 else {
            formatContext = nil
            avioProvider?.close()
            avioProvider = nil
            throw DemuxerError.openFailed(code: ret)
        }
        // avformat_open_input may reallocate, update our reference.
        formatContext = ctxPtr

        try probeStreams(ctxPtr!)
    }

    /// Default probe budgets are tuned for live network streams, 5 MB
    /// of bytes and ~5 seconds of analysed content. For big container
    /// files (10–20 GB Blu-ray rips) with sparse subtitle streams that
    /// budget runs out before libavformat sees a single PGS / DVB
    /// presentation segment, leaving those tracks with no codec
    /// parameters and the decoder unable to assemble cues — hence the
    /// 50 MB / 60 s `.playback` budget. But "LAN can move 50 MB in well
    /// under a second" does not hold for remote HTTP sources (debrid
    /// links at internet speeds), so URL opens run a `.fastProbe` first
    /// pass and only escalate to the full budget when a playable stream
    /// actually came up short (see `open(url:)`).
    private func applyProbeBudget(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        ctx.pointee.probesize = openProfile.probesize
        ctx.pointee.max_analyze_duration = openProfile.maxAnalyzeDuration
    }

    /// Demuxer options passed to every `avformat_open_input` call.
    ///
    /// `+genpts`: libavformat regenerates missing pts/dts values
    /// using its own battle-tested algorithm rather than relying on
    /// our custom NOPTS-dts repair logic. Per DrHurt's pointer on
    /// AetherEngine#4 this is the option Jellyfin's server-side
    /// remux uses for problem MKVs. Empirically cuts the long-form
    /// 4K HDR HEVC RSS growth roughly in half on Sodalite (3.24
    /// MB/sec → ~1.7 MB/sec).
    ///
    /// Tried + reverted (in this order):
    ///   `+sortdts`        — re-orders output packets by dts. Empirical
    ///                       RSS growth got worse: sortdts buffers more
    ///                       inside libavformat before yielding sorted
    ///                       packets. Also doesn't honour HEVC open-GOP
    ///                       leading B-frames in matroska.
    ///   `+discardcorrupt` — drops packets the demuxer flags as
    ///                       corrupted. AVPlayer buffers around those
    ///                       drops, RSS growth got worse.
    ///   `+igndts`         — DrHurt's suggestion (AetherEngine#5,
    ///                       2026-05-22). Tells libavformat to ignore
    ///                       container dts and infer from pts. Intent
    ///                       was to obsolete the producer-side NOPTS
    ///                       repair stack. Field test showed the
    ///                       "video dts non-monotonic at source" log
    ///                       line still fires once per producer init on
    ///                       HEVC open-GOP CRA leading B-frames — the
    ///                       matroska demuxer emits dts=0 for the
    ///                       leading B-frame even with +igndts (pts
    ///                       inference would give pts < anchor dts for
    ///                       B-frames, which would itself be wrong in
    ///                       decode order, so the demuxer keeps the
    ///                       zero). Repair stack stayed load-bearing,
    ///                       reverted to avoid carrying an option that
    ///                       doesn't change behaviour. See
    ///                       [[project_matroska_nopts_dts]].
    private static func applyDemuxerOptions(_ opts: inout OpaquePointer?, isLive: Bool = false,
                                            skipAttachments: Bool = false) {
        av_dict_set(&opts, "fflags", "+genpts", 0)
        if skipAttachments {
            // Patched matroska demuxer option (FFmpegBuild
            // 0001-matroska-skip-attachments-option): the Attachments
            // element is skipped in ONE forward jump — a remux can carry
            // tens of MB of fonts/cover art between the header and the
            // first cluster, and reading them dominates
            // avformat_open_input over a CDN (observed: 31.6 MB ≈ 30 s on
            // RD). The skip surfaces to the AVIOReader as a far forward
            // seek, which reconnects past the blob instead of streaming
            // it. Attached-font subtitle styling falls back to system
            // fonts for these sources. No-op for non-Matroska demuxers.
            av_dict_set(&opts, "skip_attachments", "1", 0)
        }
        if isLive {
            // A live HTTP source has unknown length (Content-Length absent,
            // fileSize == -1). libavformat's stream-info pass still tries to
            // estimate the duration by seeking toward SEEK_END; our reader
            // returns -1 for that seek, and the failed end-seek LATCHES
            // `pb->eof_reached`. That sticky flag then surfaces as
            // AVERROR_EOF from av_read_frame once the buffer drains the bytes
            // pulled during probing (~10 s in), ending the producer pump for
            // good even though the live feed is still streaming. Skipping the
            // PTS-based duration estimate avoids the SEEK_END entirely, so the
            // live source is never given a synthesized EOF.
            av_dict_set(&opts, "skip_estimate_duration_from_pts", "1", 0)
        }
    }

    /// Mark cover-art / attached-picture streams `AVDISCARD_ALL` before
    /// `find_stream_info`. This does NOT shorten the probe on its own
    /// (measured: discard alone still burned the full budget — libavformat's
    /// completion gate ignores discard in this build), but it keeps the
    /// muxer and `av_find_best_stream` from ever treating the cover art as a
    /// real video stream. The probe-length fix is `cappedAnalyzeForCoverArt`.
    ///
    /// Identified by codec_id (reliable: the moov sample entry already
    /// reads `png`/`mjpeg`/… at this point, even when the malformed-atom
    /// case has lost its ATTACHED_PIC disposition) plus the disposition
    /// flag (covers well-formed art). Discarded streams keep their index,
    /// so index-based selection elsewhere is unaffected.
    @discardableResult
    private func discardCoverArtStreams(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> Int {
        var discarded = 0
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let par = stream.pointee.codecpar else { continue }
            let isAttachedPic = (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
            let isImageCodec = par.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                && Self.coverArtCodecIDs.contains(par.pointee.codec_id.rawValue)
            guard isAttachedPic || isImageCodec else { continue }
            stream.pointee.discard = AVDISCARD_ALL
            discarded += 1
        }
        return discarded
    }

    /// Whether every stream the player would actually use (real video,
    /// audio, subtitles — cover art excluded) is ALREADY fully
    /// parameterized. Called right after `avformat_open_input`: for MP4/MKV
    /// the moov/headers populate codecpar immediately, so this is true;
    /// for header-light containers (TS) it's false until packets are read.
    private func realStreamsAlreadyComplete(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let par = stream.pointee.codecpar else { continue }
            if (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0 { continue }
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                if Self.coverArtCodecIDs.contains(par.pointee.codec_id.rawValue) { continue }
                if par.pointee.codec_id == AV_CODEC_ID_NONE || par.pointee.width <= 0 { return false }
            case AVMEDIA_TYPE_AUDIO:
                if par.pointee.codec_id == AV_CODEC_ID_NONE || par.pointee.sample_rate <= 0 { return false }
            case AVMEDIA_TYPE_SUBTITLE:
                if par.pointee.codec_id == AV_CODEC_ID_NONE { return false }
            default:
                continue
            }
        }
        return true
    }

    /// `max_analyze_duration` (AV_TIME_BASE units) for `find_stream_info`
    /// when the real streams are already complete at open. A hard stop on
    /// the read loop, measured in analyzed STREAM-CONTENT time, so it bounds
    /// the cover-art wait regardless of resolution/bitrate — unlike
    /// probesize, and unlike discard, both of which let the loop run to the
    /// full budget here. 1 s of content is ~24 frames at 24fps: enough for
    /// find_stream_info to confirm the container's frame rate, far below the
    /// ~2 MB the broken cover-art stream was dragging the loop to read.
    private static let coverArtAnalyzeCapUs: Int64 = 1_000_000

    /// Common stream probing after open.
    private func probeStreams(_ ctx: UnsafeMutablePointer<AVFormatContext>) throws {
        // Stop broken cover-art streams from dragging find_stream_info to
        // the probe budget (the dominant tagged-MP4 startup cost). Only when
        // every real stream is already parameterized from the container
        // header — otherwise leave the full budget so genuinely
        // under-described files (TS, sparse PGS) still probe + escalate.
        let discardedArt = discardCoverArtStreams(ctx)
        let cappedAnalyze = discardedArt > 0 && realStreamsAlreadyComplete(ctx)
        if cappedAnalyze {
            ctx.pointee.max_analyze_duration = Self.coverArtAnalyzeCapUs
        }

        let findRet = avformat_find_stream_info(ctx, nil)
        guard findRet >= 0 else {
            throw DemuxerError.streamInfoFailed(code: findRet)
        }
        if discardedArt > 0 {
            EngineLog.emit("[Demuxer] \(discardedArt) cover-art stream(s) discarded\(cappedAnalyze ? ", analyze capped at \(Self.coverArtAnalyzeCapUs / 1000)ms" : "")", category: .demux)
        }

        #if DEBUG
        EngineLog.emit("[Demuxer] Opened: \(ctx.pointee.nb_streams) streams, duration=\(ctx.pointee.duration) us", category: .demux)
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar else { continue }
            let codecType = codecpar.pointee.codec_type
            let typeName: String
            switch codecType {
            case AVMEDIA_TYPE_VIDEO: typeName = "video"
            case AVMEDIA_TYPE_AUDIO: typeName = "audio"
            case AVMEDIA_TYPE_SUBTITLE: typeName = "subtitle"
            default: typeName = "other"
            }
            EngineLog.emit("[Demuxer]   stream[\(i)] type=\(typeName) \(codecpar.pointee.width)x\(codecpar.pointee.height)", category: .demux)
        }
        #endif
    }

    /// Duration in seconds (or 0 if unknown).
    var duration: Double {
        guard let ctx = formatContext else { return 0 }
        let dur = ctx.pointee.duration
        return dur > 0 ? Double(dur) / Double(AV_TIME_BASE) : 0
    }

    /// AVFormatContext.bit_rate in bits-per-second, or 0 if unknown.
    /// libavformat computes this from the container's reported size +
    /// duration; for sources where the container doesn't expose either
    /// (some live streams, malformed files) it falls back to 0. Callers
    /// should fall back to a safe over-declared estimate when 0 is
    /// returned. Used by `HLSVideoEngine.masterBandwidth /
    /// masterAverageBandwidth` to populate the HLS master playlist's
    /// BANDWIDTH and AVERAGE-BANDWIDTH attributes from real source
    /// data instead of a hardcoded 5 Mbps default.
    var bitRate: Int64 {
        guard let ctx = formatContext else { return 0 }
        return ctx.pointee.bit_rate
    }

    /// AVFormatContext.start_time in microseconds (AV_TIME_BASE units),
    /// or 0 / AV_NOPTS_VALUE if unknown. Many MKV / TS sources have a
    /// non-zero format start_time when re-muxed from broadcast or
    /// edited from longer files; subtracting it from packet PTS yields
    /// playback time relative to the start of the file's content.
    var formatStartTime: Int64 {
        guard let ctx = formatContext else { return 0 }
        return ctx.pointee.start_time
    }

    /// Index of the best video stream, or -1 if none.
    var videoStreamIndex: Int32 {
        guard let ctx = formatContext else { return -1 }
        return av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
    }

    /// Index of the best audio stream, or -1 if none.
    var audioStreamIndex: Int32 {
        guard let ctx = formatContext else { return -1 }
        return av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
    }

    /// Extract metadata for all audio streams.
    func audioTrackInfos() -> [TrackInfo] {
        guard let ctx = formatContext else { return [] }
        var tracks: [TrackInfo] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            tracks.append(trackInfo(from: stream, index: i))
        }
        return tracks
    }

    /// Extract metadata for all subtitle streams.
    func subtitleTrackInfos() -> [TrackInfo] {
        guard let ctx = formatContext else { return [] }
        var tracks: [TrackInfo] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            tracks.append(trackInfo(from: stream, index: i))
        }
        return tracks
    }

    /// Container-level metadata (title/artist/album + embedded cover).
    /// Reads the format-context metadata dictionary; cover art comes from
    /// the stream flagged AV_DISPOSITION_ATTACHED_PIC (its `attached_pic`
    /// packet holds the encoded image bytes). Returns an all-nil value
    /// when nothing is present.
    func mediaMetadata() -> MediaMetadata {
        guard let ctx = formatContext else {
            return MediaMetadata(title: nil, artist: nil, album: nil, artworkData: nil)
        }
        let dict = ctx.pointee.metadata
        return MediaMetadata.from(
            title: metadataValue(dict, key: "title"),
            artist: metadataValue(dict, key: "artist"),
            album: metadataValue(dict, key: "album"),
            albumArtist: metadataValue(dict, key: "album_artist"),
            artworkData: attachedPictureData()
        )
    }

    /// Encoded bytes of the first attached-picture stream's cover art, or
    /// nil when the container has no embedded artwork.
    private func attachedPictureData() -> Data? {
        guard let ctx = formatContext else { return nil }
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
            else { continue }
            let pkt = stream.pointee.attached_pic
            guard pkt.size > 0, let dataPtr = pkt.data else { return nil }
            return Data(bytes: dataPtr, count: Int(pkt.size))
        }
        return nil
    }

    /// Build TrackInfo from an AVStream's metadata.
    private func trackInfo(from stream: UnsafeMutablePointer<AVStream>, index: Int) -> TrackInfo {
        let codecpar = stream.pointee.codecpar!

        // Codec name
        let codecName: String
        if let codec = avcodec_find_decoder(codecpar.pointee.codec_id) {
            codecName = String(cString: codec.pointee.name)
        } else {
            codecName = "unknown"
        }

        // Language and title from stream metadata
        let language = metadataValue(stream.pointee.metadata, key: "language")
        let title = metadataValue(stream.pointee.metadata, key: "title")

        // Build display name
        let name: String
        if let title = title, !title.isEmpty {
            name = title
        } else if let lang = language {
            name = "\(lang.uppercased()) (\(codecName))"
        } else {
            name = "Track \(index) (\(codecName))"
        }

        let isDefault = (stream.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0
        let channels = Int(codecpar.pointee.ch_layout.nb_channels)

        // Atmos detection mirrors the gate used by the audio engine
        // selectAudioTrack path: EAC3 with profile 30 = JOC, which is
        // what every Dolby-Atmos-on-streaming elementary stream is in
        // practice. Lets the UI label the row "Atmos" instead of just
        // its bed channel count.
        let isAtmos = (codecpar.pointee.codec_id == AV_CODEC_ID_EAC3)
            && codecpar.pointee.profile == 30

        // ASS / SSA tracks carry their script header ([Script Info] +
        // [V4+ Styles] + the [Events] format line) as codec extradata.
        // Surface it so hosts that opt into raw ASS event lines
        // (LoadOptions.preserveASSMarkup) can resolve style references.
        var assHeader: String? = nil
        let codecID = codecpar.pointee.codec_id
        if codecID == AV_CODEC_ID_ASS || codecID == AV_CODEC_ID_SSA,
           let extradata = codecpar.pointee.extradata,
           codecpar.pointee.extradata_size > 0 {
            let bytes = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            // Strip NUL bytes: MKV CodecPrivate is frequently
            // NUL-terminated, and downstream consumers (libass parses
            // C-string-style) silently stop at the first NUL, hiding
            // anything a host appends after the header.
            assHeader = String(data: bytes, encoding: .utf8)?
                .replacingOccurrences(of: "\0", with: "")
        }

        return TrackInfo(
            id: index,
            name: name,
            codec: codecName,
            language: language,
            channels: channels,
            isDefault: isDefault,
            isAtmos: isAtmos,
            assHeader: assHeader
        )
    }

    /// Font files attached to the container (MKV attachment streams).
    /// Payload bytes live in the attachment stream's codec extradata;
    /// filename and MIME type in its stream metadata. Non-font
    /// attachments (cover art lives on ATTACHED_PIC video streams and
    /// never reaches here; chapters/XML attachments are filtered by
    /// the MIME/extension check) are skipped.
    func fontAttachmentInfos() -> [FontAttachment] {
        guard let ctx = formatContext else { return [] }
        var fonts: [FontAttachment] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT,
                  let extradata = codecpar.pointee.extradata,
                  codecpar.pointee.extradata_size > 0
            else { continue }
            let filename = metadataValue(stream.pointee.metadata, key: "filename")
            let mimeType = metadataValue(stream.pointee.metadata, key: "mimetype")
            guard FontAttachment.isFontPayload(mimeType: mimeType, filename: filename) else { continue }
            let fallbackExt: String
            switch mimeType?.lowercased() {
            case "font/otf", "application/vnd.ms-opentype", "application/x-font-otf": fallbackExt = "otf"
            case "font/collection": fallbackExt = "ttc"
            default: fallbackExt = "ttf"
            }
            fonts.append(FontAttachment(
                filename: filename ?? "font-\(i).\(fallbackExt)",
                mimeType: mimeType ?? "",
                data: Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            ))
        }
        return fonts
    }

    /// Read a metadata value from an AVDictionary.
    private func metadataValue(_ dict: OpaquePointer?, key: String) -> String? {
        guard let dict = dict else { return nil }
        guard let entry = av_dict_get(dict, key, nil, 0) else { return nil }
        return String(cString: entry.pointee.value)
    }

    /// Access an AVStream by index.
    func stream(at index: Int32) -> UnsafeMutablePointer<AVStream>? {
        guard let ctx = formatContext, index >= 0, index < ctx.pointee.nb_streams else {
            return nil
        }
        return ctx.pointee.streams[Int(index)]
    }

    /// Mark every stream outside `keep` with `AVDISCARD_ALL` so the
    /// demuxer skips parsing + queueing its packets at the lowest
    /// level. For our 4K HDR HEVC sources with 4 PGS subtitle streams
    /// (large per-frame bitmaps) and 2 audio streams the matroska
    /// demuxer otherwise reads cluster blocks for all 7 streams every
    /// time it serves a video packet, parses them, and queues them in
    /// its per-stream packet queue waiting for someone to ask. Our
    /// pump silently drops them via `continue` at the consumer side,
    /// but by then the demuxer has already done the work and the
    /// queues hold the packets until av_read_frame iterates them out
    /// and our pump throws them away.
    ///
    /// With `discard = AVDISCARD_ALL` the demuxer drops the packet
    /// before parsing it into an AVPacket, eliminating the alloc +
    /// queue + free cycle for every subtitle bitmap and unused audio
    /// frame. Counted against the long-form 4K HDR RSS leak this is
    /// directly proportional: PGS bitmap rate × ~4 streams cuts to
    /// zero.
    ///
    /// Call after `avformat_find_stream_info` (i.e. after open
    /// returns) and before any `readPacket` calls. Safe to call
    /// multiple times.
    func discardAllStreamsExcept(_ keep: Set<Int32>) {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return }
        for i in 0..<Int32(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[Int(i)] else { continue }
            // AVDISCARD_DEFAULT = 0 (= passthrough), AVDISCARD_ALL = 48.
            stream.pointee.discard = keep.contains(i)
                ? AVDISCARD_DEFAULT
                : AVDISCARD_ALL
        }
    }

    /// Enumerate the source's keyframe positions for the given stream
    /// from libavformat's index, returning each entry's `timestamp`
    /// field in the stream's native timebase.
    ///
    /// MKV / Matroska sources populate their index from the `Cues`
    /// element, which is parsed lazily on the first seek. To get a
    /// useful answer from this method on those sources, the caller
    /// must have already issued a seek (the cue-prewarm in
    /// `HLSVideoEngine.start()` does this). Sources that ship a
    /// keyframe index in their header (MP4 `stss`, MPEG-TS pcr-based,
    /// etc.) populate it during `avformat_find_stream_info` and are
    /// ready immediately.
    ///
    /// Returns an empty array when the index is empty or the stream
    /// index is invalid — callers should treat that as "no usable
    /// index, fall back to a uniform-stride plan".
    ///
    /// FFmpeg's index entries are all keyframe seek points by
    /// definition; the `AVINDEX_KEYFRAME` bit is checked defensively
    /// in case a future libavformat version starts mixing
    /// non-keyframe seek targets in.
    func indexedKeyframes(streamIndex: Int32) -> [Int64] {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext,
              streamIndex >= 0,
              streamIndex < Int32(ctx.pointee.nb_streams),
              let stream = ctx.pointee.streams[Int(streamIndex)] else {
            return []
        }
        let count = avformat_index_get_entries_count(stream)
        guard count > 0 else { return [] }
        var result: [Int64] = []
        result.reserveCapacity(Int(count))
        for i in 0..<count {
            guard let entry = avformat_index_get_entry(stream, i) else { continue }
            // AVINDEX_KEYFRAME = 0x0001
            if entry.pointee.flags & 0x0001 != 0,
               entry.pointee.timestamp != Int64.min {
                result.append(entry.pointee.timestamp)
            }
        }
        return result
    }

    /// Read the next packet from the container.
    /// Returns the packet on success, nil at EOF.
    /// Throws on read errors (network failure, corrupt data, etc).
    func readPacket() throws -> UnsafeMutablePointer<AVPacket>? {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return nil }
        var packet: UnsafeMutablePointer<AVPacket>? = trackedPacketAlloc()
        guard packet != nil else { return nil }
        let ret = av_read_frame(ctx, packet)
        if ret < 0 {
            trackedPacketFree(&packet)
            let isEOF = (ret == FFmpegErr.eof)
            if isEOF {
                return nil
            }
            throw DemuxerError.readFailed(code: ret)
        }
        return packet
    }

    /// Seek to a position in seconds.
    /// Uses avformat_seek_file instead of av_seek_frame, more robust
    /// for MKV containers (av_seek_frame triggers assertion failures
    /// in matroskadec.c with nested elements).
    func seek(to seconds: Double) {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return }
        let timestamp = Int64(seconds * Double(AV_TIME_BASE))
        let ret = avformat_seek_file(ctx, -1, Int64.min, timestamp, Int64.max, 0)
        if ret < 0 {
            #if DEBUG
            EngineLog.emit("[Demuxer] Seek to \(seconds)s failed: \(ret)", category: .demux)
            #endif
        }
        // Flush internal parser state after seek, prevents assertion
        // failures in matroskadec.c when reading the next packet.
        avformat_flush(ctx)
    }

    /// Fast, lock-free unblock: mark the AVIO reader closed so its read
    /// callback returns -1 immediately and a suspended `av_read_frame`
    /// (including one parked in the live reconnect loop) returns at once.
    /// Frees no resources. Call this synchronously when cancelling a pump so
    /// the pump can unwind without waiting on the (potentially slow) `close()`
    /// teardown. Idempotent; `close()` calls it again before freeing.
    func markClosed() {
        markLock.lock()
        markedClosed = true
        markLock.unlock()
        avioProvider?.markClosed()
    }

    /// Close the format context and release resources.
    /// Thread-safe: waits for any in-progress readPacket() to finish
    /// before freeing the format context. The AVIO reader is marked
    /// closed first so its callback returns -1 immediately, unblocking
    /// any suspended av_read_frame call.
    func close() {
        // 1. Mark AVIO as closed, read callback returns -1 immediately.
        //    This unblocks av_read_frame if the demux thread is suspended
        //    inside a read (tvOS suspends threads in background).
        avioProvider?.markClosed()

        // 2. Wait for readPacket() to release the lock, then tear down.
        accessLock.lock()
        if formatContext != nil {
            avformat_close_input(&formatContext)
        }
        formatContext = nil
        accessLock.unlock()

        avioProvider?.close()
        avioProvider = nil
    }

    deinit {
        close()
    }
}

enum DemuxerError: Error {
    case openFailed(code: Int32)
    case streamInfoFailed(code: Int32)
    case readFailed(code: Int32)
}
