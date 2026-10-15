module Core.APU;

import std.stdio;
import std.math;
import std.algorithm;

import Core.Gameboy;
import Core.MMU;
import Core.IGameboyDevice;

import Core.Audio.IChannel;
import Core.Audio.Channel0;
import Core.Audio.Channel1;
import Core.Audio.Channel2;
import Core.Audio.Channel3;

import Interface.IAudioOut;


// Sound registers read back as written, with unused and write-only bits reading as 1.
// NR52 instead reads the power and channel status.
private immutable ubyte[IO.SND52 - IO.SND10 + 1] READ_MASKS = [
    0x80, 0x3F, 0x00, 0xFF, 0xBF,
    0xFF, 0x3F, 0x00, 0xFF, 0xBF,
    0x7F, 0xFF, 0x9F, 0xFF, 0xBF,
    0xFF, 0xFF, 0x00, 0x00, 0xBF,
    0x00, 0x00, 0x70,
];

public struct GBSample {
    double l = 0.0;
    double r = 0.0;
}

public final class APU : IGameboyDevice {
    private Gameboy _gameboy;

    private IChannel[4] _channels;
    private ubyte[READ_MASKS.length] _registers;

    private bool _enabled;

    private bool[4] _channelToOutL;
    private bool[4] _channelToOutR;

    private bool _vinToOutL;
    private bool _vinToOutR;

    private ubyte _outLVolume;
    private ubyte _outRVolume;

    private GBSample _systemSampleSum;
    private double _systemSampleCycles;
    private double _cyclesPerSystemSample;
    private double _baseCyclesPerSystemSample;
    private AudioBufferCallback _bufferFunc;

    private GBSample _highpassDiff;
    private double _highpassRate;
    private bool _highpassEnabled;

    public this() {
        _channels[0] = new Channel0();
        _channels[1] = new Channel1();
        _channels[2] = new Channel2();
        _channels[3] = new Channel3();
    }

    public void attach(Gameboy gameboy) {
        _gameboy = gameboy;
    }

    public void reset() {
        _enabled = false;

        _channelToOutL[] = false;
        _channelToOutR[] = false;

        _vinToOutL = false;
        _vinToOutR = false;

        _outLVolume = 0;
        _outRVolume = 0;

        _registers[] = 0;

        _systemSampleSum.l = 0.0;
        _systemSampleSum.r = 0.0;
        _systemSampleCycles = 0.0;

        _highpassDiff.l = 0.0;
        _highpassDiff.r = 0.0;
        _highpassRate = 1.0;

        foreach (IChannel channel; _channels) {
            channel.reset();
        }
    }

    public void cycle() {
        if (isNaN(_cyclesPerSystemSample)) {
            return;
        }

        // Tick twice since the audio is run at 2Mhz (2x per 4 cycles).
        for (int i = 0; i < 2; i ++) {

            // TODO: align to clock so that start\end of square pattern is a direct jump instead of an averaged sample?

            GBSample currentSample;
            if (_enabled) {
                foreach (int index, IChannel channel; _channels) {
                    immutable double sample = channel.cycle();

                    // Normalize for 4 channel maximum per stereo side.
                    if (_channelToOutL[index]) {
                        currentSample.l += sample * 0.25;
                    }
                    if (_channelToOutR[index]) {
                        currentSample.r += sample * 0.25;
                    }
                }
            }

            // Set output stereo channel volume.
            // TODO: https://gbdev.gg8.se/wiki/articles/Gameboy_sound_hardware#Mixer
            currentSample.l *= _outLVolume / 7.0;
            currentSample.r *= _outRVolume / 7.0;

            // Add to current sample.
            _systemSampleSum.l += currentSample.l;
            _systemSampleSum.r += currentSample.r;

            // Output a system sample if enough cycles have passed that one has to be generated.
            _systemSampleCycles++;
            if (_systemSampleCycles >= _cyclesPerSystemSample) {

                // Average the summed sample over the number of cycles that were used to generate it.
                // The sample cycle divisor is truncated because we generated a sum of complete samples up to this point.
                _systemSampleSum.l /= cast(int)_systemSampleCycles;
                _systemSampleSum.r /= cast(int)_systemSampleCycles;

                // Apply a highpass filter at rate appropriate for the current system samplerate.
                // https://gbdev.gg8.se/wiki/articles/Gameboy_sound_hardware#Obscure_Behavior
                if (_highpassEnabled) {
                    GBSample filteredSample = {
                        _systemSampleSum.l - _highpassDiff.l,
                        _systemSampleSum.r - _highpassDiff.r,
                    };
                    _highpassDiff.l = _systemSampleSum.l - filteredSample.l * _highpassRate;
                    _highpassDiff.r = _systemSampleSum.r - filteredSample.r * _highpassRate;

                    _bufferFunc([filteredSample.l, filteredSample.r]);
                } else {
                    _bufferFunc([_systemSampleSum.l, _systemSampleSum.r]);
                }

                _systemSampleCycles -= _cyclesPerSystemSample;
                _systemSampleSum.l = 0.0;
                _systemSampleSum.r = 0.0;
            }
        }
    }

    public ubyte readIO(immutable ushort address) {
        immutable size_t index = address - IO.SND10;
        if (address != IO.SND52) {
            return _registers[index] | READ_MASKS[index];
        }

        ubyte value = READ_MASKS[index];
        value |= _enabled ? 0x80 : 0;
        foreach (int channel; 0 .. cast(int)_channels.length) {
            value |= _channels[channel].active ? 1 << channel : 0;
        }
        return value;
    }

    // TODO: if powered off, writes to registers are ignored, except for DMG
    // https://gbdev.gg8.se/wiki/articles/Gameboy_sound_hardware#Power_Control
    public void writeIO(immutable ushort address, immutable ubyte data) {
        _registers[address - IO.SND10] = data;

        switch (address) {
            case IO.SND10:
            ..
            case IO.SND14:
                _channels[0].writeIO(address, data);
                break;

            case IO.SND21:
            ..
            case IO.SND24:
                _channels[1].writeIO(address, data);
                break;

            case IO.SND30:
            ..
            case IO.SND34:
                _channels[2].writeIO(address, data);
                break;

            case IO.SND41:
            ..
            case IO.SND44:
                _channels[3].writeIO(address, data);
                break;

            case IO.SND50:
                _vinToOutL = cast(bool)(data & 0x04);
                _vinToOutR = cast(bool)(data & 0x40);
                _outLVolume = data & 0x07;
                _outRVolume = (data & 0x70) >> 4;
                break;

            case IO.SND51:
                _channelToOutL[0] = cast(bool)(data & 0x01);
                _channelToOutL[1] = cast(bool)(data & 0x02);
                _channelToOutL[2] = cast(bool)(data & 0x04);
                _channelToOutL[3] = cast(bool)(data & 0x08);
                _channelToOutR[0] = cast(bool)(data & 0x10);
                _channelToOutR[1] = cast(bool)(data & 0x20);
                _channelToOutR[2] = cast(bool)(data & 0x40);
                _channelToOutR[3] = cast(bool)(data & 0x80);
                break;

            case IO.SND52:
                _enabled = cast(bool)(data & 0x80);
                break;

            default:
                break;
        }
    }

    public ubyte readWave(immutable ushort address) {
        return (cast(Channel2)_channels[2]).readWave(address);
    }

    public void writeWave(immutable ushort address, immutable ubyte data) {
        (cast(Channel2)_channels[2]).writeWave(address, data);
    }

    public IChannel channel(immutable uint index) {
        return _channels[index];
    }

    public void setSystemSampleRate(immutable uint systemSampleRate) {
        _baseCyclesPerSystemSample = (cast(double)_gameboy.clockRate / cast(double)systemSampleRate) / 2.0;
        _cyclesPerSystemSample = _baseCyclesPerSystemSample;

        // TODO: 0.998943 for MGB\CGB
        _highpassRate = pow(0.999958, cast(double)_gameboy.clockRate / cast(double)systemSampleRate);
        
        writefln("%06f cycles per system sample, %.08f highpass rate", _cyclesPerSystemSample, _highpassRate);
    }

    // Scales the output sample rate by ratio, to keep pace with the audio device's clock.
    public void adjustSampleRate(immutable double ratio) {
        _cyclesPerSystemSample = _baseCyclesPerSystemSample / ratio;
    }

    @property
    public void bufferFullFunction(AudioBufferCallback func) {
        _bufferFunc = func;
    }

    @property
    public void setHighpassFilterEnabled(bool enabled) {
        _highpassEnabled = enabled;
    }
}