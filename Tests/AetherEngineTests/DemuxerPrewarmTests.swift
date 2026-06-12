import Testing
import Foundation
@testable import AetherEngine

struct DemuxerPrewarmTests {
    /// Connection-refused fast: nothing listens on port 1, so opens against
    /// it fail in milliseconds without leaving sockets behind.
    private static let unreachableURL = URL(string: "http://127.0.0.1:1/never.mp4")!

    @Test("abort before open cancels the open without dialing the network")
    func abortBeforeOpen() {
        let handle = DemuxerPrewarm(url: Self.unreachableURL)
        handle.abort()
        #expect(throws: CancellationError.self) { try handle.open() }
        #expect(handle.takeDemuxer() == nil)
    }

    @Test("abort is idempotent and take after abort stays nil")
    func abortIdempotent() {
        let handle = DemuxerPrewarm(url: Self.unreachableURL)
        handle.abort()
        handle.abort()
        #expect(handle.takeDemuxer() == nil)
    }

    @Test("take transfers ownership exactly once; abort afterwards is a no-op")
    func takeThenAbort() {
        let handle = DemuxerPrewarm(url: Self.unreachableURL)
        #expect(handle.takeDemuxer() != nil)
        handle.abort()
        #expect(handle.takeDemuxer() == nil)
    }

    /// Regression for the superseded-prewarm crash: abort() used to free the
    /// AVFormatContext / AVIO buffers from the aborting thread while the open
    /// thread was still inside avformat_open_input — a use-after-free
    /// (EXC_BAD_ACCESS on device when a second verify-ahead superseded the
    /// first). abort() must only unblock an in-flight open; the teardown
    /// belongs to the opening thread after FFmpeg returns. This drives the
    /// abort across the open's lifetime windows repeatedly; a regression
    /// shows up as a crash, a hang (open never returning), or a non-nil take.
    @Test("abort racing an in-flight open returns promptly and never crashes")
    func abortDuringOpenRace() async {
        for iteration in 0..<30 {
            let handle = DemuxerPrewarm(url: Self.unreachableURL)
            let opener = Task.detached(priority: .userInitiated) {
                try? handle.open()
            }
            // Vary the abort's landing spot: immediately, and after a few
            // milliseconds so some iterations catch the open mid-flight.
            if iteration % 2 == 1 {
                try? await Task.sleep(for: .milliseconds(iteration % 7))
            }
            handle.abort()
            _ = await opener.value
            #expect(handle.takeDemuxer() == nil)
        }
    }
}
