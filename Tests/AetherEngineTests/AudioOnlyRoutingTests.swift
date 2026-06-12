import Testing
@testable import AetherEngine

@Suite("Audio-only routing decision")
struct AudioOnlyRoutingTests {

    @Test("Explicit audioOnly forces the audio path even with a video stream")
    func explicitFlagForcesAudio() {
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: true, probeSucceeded: true, hasVideoStream: true) == true)
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: true, probeSucceeded: true, hasVideoStream: false) == true)
        // The flag is the host's explicit choice; it holds even when the
        // probe failed (the audio host reopens the URL itself).
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: true, probeSucceeded: false, hasVideoStream: false) == true)
    }

    @Test("Probed source without a video stream routes to the audio path")
    func noVideoRoutesAudio() {
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: false, probeSucceeded: true, hasVideoStream: false) == true)
    }

    @Test("Video stream without the flag stays on the video path")
    func videoStaysVideo() {
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: false, probeSucceeded: true, hasVideoStream: true) == false)
    }

    /// Regression: a FAILED probe must not read as "no video stream".
    /// Routing a movie whose probe hit transient network garbage into the
    /// audio path guaranteed a dead session (no audio either → noAudioStream)
    /// instead of letting the video dispatch reopen the URL fresh.
    @Test("Failed probe stays on the video path so the dispatch can reopen")
    func failedProbeStaysVideo() {
        #expect(AetherEngine.shouldUseAudioOnlyPath(audioOnlyRequested: false, probeSucceeded: false, hasVideoStream: false) == false)
    }
}
