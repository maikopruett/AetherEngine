import Foundation

/// Opens a demuxer AHEAD of a play tap so the dominant tap-to-first-frame
/// cost — `avformat_open_input` + `find_stream_info` (the moov fetch +
/// stream probe, seconds over a slow CDN) — is already paid when the user
/// taps. Hand the opened demuxer to `AetherEngine.load(preopenedDemuxer:)`
/// and the engine adopts it, skipping the open entirely.
///
/// The reason this is a handle and not a plain `openDemuxer(url:) -> Demuxer`
/// call: the open is a multi-second blocking network read. When the user's
/// focus moves to another title (or backs out), the speculative read must
/// stop IMMEDIATELY so it doesn't keep competing for bandwidth with whatever
/// the user actually plays. `abort()` unblocks an in-flight open at once
/// (the AVIOReader's read callback returns -1), instead of letting it run to
/// completion before being discarded.
///
/// Lifecycle: `open()` once, off the main actor (it blocks). Then exactly
/// one of `takeDemuxer()` (hand to `load`) or `abort()` (cancel). `abort()`
/// is safe to call from any thread, before/during/after `open()`, and is
/// idempotent — call it on supersede, back-out, or a claim miss.
public final class DemuxerPrewarm: @unchecked Sendable {
    private let demuxer = Demuxer()
    private let url: URL
    private let options: LoadOptions
    private let lock = NSLock()
    private var aborted = false
    private var taken = false

    /// Open it with the SAME `options` the eventual `load` will use
    /// (`httpHeaders`, `isLive`): the demuxer is reused as the session
    /// demuxer, so its AVIOReader must already be configured to match.
    public init(url: URL, options: LoadOptions = .init()) {
        self.url = url
        self.options = options
    }

    /// Run the open synchronously. Blocks on network I/O — dispatch off the
    /// main actor. Throws if the open fails or `abort()` unblocked it; the
    /// caller can ignore the throw and rely on `takeDemuxer()` returning nil.
    public func open() throws {
        try demuxer.open(url: url, extraHeaders: options.httpHeaders, isLive: options.isLive)
    }

    /// Transfer the opened demuxer to a `load(preopenedDemuxer:)` call,
    /// transferring ownership (the engine closes it when the session ends).
    /// Returns nil if `abort()` was called or it was already taken — the
    /// caller then loads normally (the engine opens its own demuxer).
    public func takeDemuxer() -> Demuxer? {
        lock.lock(); defer { lock.unlock() }
        guard !aborted, !taken else { return nil }
        taken = true
        return demuxer
    }

    /// Abort an in-flight open and free the demuxer. After this,
    /// `takeDemuxer()` returns nil. No-op once the demuxer has been taken
    /// (ownership already transferred to a load). Idempotent, any thread.
    public func abort() {
        lock.lock()
        if taken || aborted { lock.unlock(); return }
        aborted = true
        lock.unlock()
        // markClosed() makes a blocked avformat_open_input / find_stream_info
        // return -1 at once; close() frees the context.
        demuxer.markClosed()
        demuxer.close()
    }
}
