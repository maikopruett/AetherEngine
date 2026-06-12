import Testing
import Libavcodec
import Libavutil
@testable import AetherEngine

/// `aacASCUsesPCE` guards the fMP4 stream-copy path: AAC whose
/// AudioSpecificConfig declares channelConfiguration = 0 carries its
/// channel map in an in-band PCE, which AudioToolbox cannot decode —
/// stream-copied it fails the whole AVPlayer item with -11829 /
/// CoreMediaErrorDomain -12848. Such tracks must take the FLAC bridge.
@Suite("AAC PCE channel-config detection")
struct AACPCEDetectionTests {

    /// Codecpar with the given extradata installed; caller must free.
    private func codecpar(
        extradata: [UInt8], codecID: AVCodecID = AV_CODEC_ID_AAC
    ) -> UnsafeMutablePointer<AVCodecParameters> {
        let par = avcodec_parameters_alloc()!
        par.pointee.codec_id = codecID
        if !extradata.isEmpty {
            let buf = av_malloc(extradata.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))!
                .assumingMemoryBound(to: UInt8.self)
            extradata.withUnsafeBufferPointer { src in
                memcpy(buf, src.baseAddress!, extradata.count)
            }
            memset(buf + extradata.count, 0, Int(AV_INPUT_BUFFER_PADDING_SIZE))
            par.pointee.extradata = buf
            par.pointee.extradata_size = Int32(extradata.count)
        }
        return par
    }

    private func usesPCE(_ extradata: [UInt8], codecID: AVCodecID = AV_CODEC_ID_AAC) -> Bool {
        var par: UnsafeMutablePointer<AVCodecParameters>? = codecpar(extradata: extradata, codecID: codecID)
        defer { avcodec_parameters_free(&par) }
        return HLSVideoEngine.aacASCUsesPCE(par!)
    }

    @Test("standard stereo ASC is not PCE")
    func standardStereo() {
        // AOT 2 (LC), freqIdx 3 (48 kHz), channelConfiguration 2.
        #expect(usesPCE([0x12, 0x10]) == false)
    }

    @Test("standard 5.1 ASC is not PCE")
    func standardFiveOne() {
        // AOT 2 (LC), freqIdx 3 (48 kHz), channelConfiguration 6.
        #expect(usesPCE([0x11, 0xB0]) == false)
    }

    @Test("channelConfiguration 0 (in-band PCE) is detected")
    func pceConfig() {
        // Head of the field-repro ASC ("Spirited Away [WeSLeY]", Lavc62
        // 5.1(side)): AOT 2 (LC), freqIdx 3 (48 kHz), channelConfiguration 0,
        // PCE payload following.
        let asc: [UInt8] = [0x11, 0x80, 0x04, 0xC8, 0x44, 0x00, 0x20, 0x00, 0xC4]
        #expect(usesPCE(asc) == true)
    }

    @Test("explicit-sample-rate escape is parsed past")
    func explicitSampleRateEscape() {
        // AOT 2 (LC), freqIdx 15 (escape), 24-bit rate 48000, then chanConfig.
        // Bits: 00010 1111 000000001011101110000000 cccc ...
        func asc(chanConfig: UInt8) -> [UInt8] {
            var bits = "00010" + "1111" + String(48000, radix: 2).leftPadded(to: 24)
            bits += String(chanConfig, radix: 2).leftPadded(to: 4)
            bits += "000"  // GASpecificConfig padding
            return stride(from: 0, to: bits.count, by: 8).map { i in
                let start = bits.index(bits.startIndex, offsetBy: i)
                let end = bits.index(start, offsetBy: min(8, bits.count - i))
                return UInt8(String(bits[start..<end]).rightPadded(to: 8), radix: 2)!
            }
        }
        #expect(usesPCE(asc(chanConfig: 0)) == true)
        #expect(usesPCE(asc(chanConfig: 6)) == false)
    }

    @Test("non-AAC and missing extradata are not flagged")
    func guards() {
        #expect(usesPCE([0x11, 0x80], codecID: AV_CODEC_ID_AC3) == false)
        #expect(usesPCE([]) == false)
        #expect(usesPCE([0x11]) == false)
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
    func rightPadded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: "0", count: width - count)
    }
}
