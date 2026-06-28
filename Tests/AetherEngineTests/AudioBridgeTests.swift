import Testing
import Libavcodec
import Libavutil
@testable import AetherEngine

@Suite("AudioBridge")
struct AudioBridgeTests {

    @Test("surround bridge uses an EAC3-compatible encoder rate")
    func surroundBridgeUsesEAC3CompatibleEncoderRate() {
        #expect(AudioBridge.encoderSampleRate(forSourceSampleRate: 96_000, mode: .surroundCompat) == 48_000)
        #expect(AudioBridge.encoderSampleRate(forSourceSampleRate: 88_200, mode: .surroundCompat) == 44_100)
        #expect(AudioBridge.encoderSampleRate(forSourceSampleRate: 48_000, mode: .surroundCompat) == 48_000)
        #expect(AudioBridge.encoderSampleRate(forSourceSampleRate: 44_100, mode: .surroundCompat) == 44_100)
        #expect(AudioBridge.encoderSampleRate(forSourceSampleRate: 32_000, mode: .surroundCompat) == 32_000)
        #expect(AudioBridge.encoderSampleRate(forSourceSampleRate: 0, mode: .surroundCompat) == 48_000)
    }

    @Test("lossless bridge preserves source encoder rate")
    func losslessBridgePreservesSourceEncoderRate() {
        #expect(AudioBridge.encoderSampleRate(forSourceSampleRate: 96_000, mode: .lossless) == 96_000)
        #expect(AudioBridge.encoderSampleRate(forSourceSampleRate: 44_100, mode: .lossless) == 44_100)
        #expect(AudioBridge.encoderSampleRate(forSourceSampleRate: 0, mode: .lossless) == 48_000)
    }

    @Test("surround bridge opens high-rate PCM by resampling to EAC3 rate")
    func surroundBridgeOpensHighRatePCM() throws {
        var params: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        let codecpar = try #require(params)
        defer { avcodec_parameters_free(&params) }

        codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        codecpar.pointee.codec_id = AV_CODEC_ID_PCM_S24LE
        codecpar.pointee.sample_rate = 96_000
        av_channel_layout_default(&codecpar.pointee.ch_layout, 6)

        let bridge = try AudioBridge(
            srcCodecpar: codecpar,
            srcTimeBase: AVRational(num: 1, den: 96_000),
            mode: .surroundCompat
        )
        defer { bridge.close() }

        #expect(bridge.encoderCodecpar?.pointee.codec_id == AV_CODEC_ID_EAC3)
        #expect(bridge.encoderCodecpar?.pointee.sample_rate == 48_000)
        #expect(bridge.encoderTimeBase.den == 48_000)
    }
}
