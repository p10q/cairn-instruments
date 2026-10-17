@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

private final class SoundFontRenderBuffers {
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    deinit { list.unsafeMutablePointer.deallocate() }
}

/// Create and load outside the audio callback. One owner renders and sends MIDI events.
public final class SoundFontRenderer {
    private let sampler = AVAudioUnitSampler()
    private let storage = SoundFontRenderBuffers()
    private var sampleTime: Double = 0

    public init(url: URL, preset: SoundFontPreset, sampleRate: Double = 48_000) throws {
        try preset.validate()
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else {
            throw InstrumentFailure.invalidPreset
        }
        guard try SoundFontBank(url: url).presets.contains(preset) else { throw InstrumentFailure.invalidPreset }
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        try Self.check(AudioUnitSetProperty(sampler.audioUnit, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Output, 0, &format,
                                           UInt32(MemoryLayout.size(ofValue: format))))
        var maximumFrames: UInt32 = 4096
        try Self.check(AudioUnitSetProperty(sampler.audioUnit, kAudioUnitProperty_MaximumFramesPerSlice,
                                           kAudioUnitScope_Global, 0, &maximumFrames,
                                           UInt32(MemoryLayout.size(ofValue: maximumFrames))))
        try sampler.loadSoundBankInstrument(
            at: url, program: preset.program,
            bankMSB: UInt8(preset.isDrumKit ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB),
            bankLSB: preset.isDrumKit ? 0 : UInt8(preset.bank)
        )
        try Self.check(AudioUnitInitialize(sampler.audioUnit))
    }

    deinit {
        AudioUnitUninitialize(sampler.audioUnit)
    }

    @discardableResult
    public func noteOn(pitch: UInt8, velocity: UInt8, offset: UInt32 = 0, channel: UInt8 = 0) -> OSStatus {
        guard pitch < 128, velocity < 128, channel < 16 else { return kAudioUnitErr_InvalidParameter }
        return MusicDeviceMIDIEvent(sampler.audioUnit, 0x90 | UInt32(channel), UInt32(pitch), UInt32(velocity), offset)
    }

    @discardableResult
    public func noteOff(pitch: UInt8, offset: UInt32 = 0, channel: UInt8 = 0) -> OSStatus {
        guard pitch < 128, channel < 16 else { return kAudioUnitErr_InvalidParameter }
        return MusicDeviceMIDIEvent(sampler.audioUnit, 0x80 | UInt32(channel), UInt32(pitch), 0, offset)
    }

    @discardableResult
    public func silence(offset: UInt32 = 0, channel: UInt8 = 0) -> OSStatus {
        guard channel < 16 else { return kAudioUnitErr_InvalidParameter }
        return MusicDeviceMIDIEvent(sampler.audioUnit, 0xb0 | UInt32(channel), 120, 0, offset)
    }

    /// MIDI offsets refer to this block. Buffers contain non-interleaved stereo Float32.
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                       count: UInt32) -> OSStatus {
        guard count > 0, count <= 4096 else { return kAudioUnitErr_TooManyFramesToProcess }
        let buffers = storage.list
        buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: count * 4, mData: left)
        buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: count * 4, mData: right)
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid
        var flags = AudioUnitRenderActionFlags(rawValue: 0)
        let status = AudioUnitRender(sampler.audioUnit, &flags, &timestamp, 0, count, buffers.unsafeMutablePointer)
        sampleTime += Double(count)
        return status
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw InstrumentFailure.audio(status) }
    }
}
