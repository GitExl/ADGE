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
import Interface.SDL.SystemTimer;


public struct GBSample {
    double l = 0.0;
    double r = 0.0;
}

public final class APU : IGameboyDevice {
	private Gameboy _gameboy;

    private IChannel[4] _channels;

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
    private AudioBufferCallback _bufferFunc;

    private GBSample _highpassDiff;
    private double _highpassRate;
    private bool _highpassEnabled;

    private int sp;
    private int cc;
    private ulong tstart;
    private ulong ts;
    private SystemTimer t;

    public this() {
        _channels[0] = new Channel0();
        _channels[1] = new Channel1();
        _channels[2] = new Channel2();
        _channels[3] = new Channel3();

        t = new SystemTimer();
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

        _systemSampleSum.l = 0.0;
        _systemSampleSum.r = 0.0;
        _systemSampleCycles = 0.0;

        _highpassDiff.l = 0.0;
        _highpassDiff.r = 0.0;
        _highpassRate = 1.0;

        foreach (IChannel channel; _channels) {
            channel.reset();
        }

        tstart = t.getCounter();
        ts = t.getCounter();
	}

	public void cycle() {
        cc += 4;
        if (t.getCounter() - ts >= 1000000) {
            ts = t.getCounter();
            writefln("APU: %d cycles", cc);
            cc = 0;
        }
        
        if (_cyclesPerSystemSample == double.nan) {
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

                sp++;
                ulong el = t.getCounter();
                if (el - tstart >= 1000000) {
                    tstart = el;
                    writefln("%d samples\\s, %.03f cycles", sp, _systemSampleCycles);
                    sp = 0;
                }

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
        switch (address) {
            case IO.SND50:
                ubyte value;
                value |= _vinToOutL ? 0x04 : 0;
                value |= _vinToOutR ? 0x40 : 0;
                value |= _outLVolume;
                value |= _outRVolume << 4;
                return value;

            case IO.SND51:
                ubyte value;
                value |= _channelToOutL[0] ? 0x01 : 0;
                value |= _channelToOutL[1] ? 0x02 : 0;
                value |= _channelToOutL[2] ? 0x04 : 0;
                value |= _channelToOutL[3] ? 0x08 : 0;
                value |= _channelToOutR[0] ? 0x10 : 0;
                value |= _channelToOutR[1] ? 0x20 : 0;
                value |= _channelToOutR[2] ? 0x40 : 0;
                value |= _channelToOutR[3] ? 0x80 : 0;
                return value;

            case IO.SND52:
                ubyte value;
                value |= _enabled ? 0x80 : 0;
                value |= _channels[0].active ? 0x01 : 0;
                value |= _channels[1].active ? 0x02 : 0;
                value |= _channels[2].active ? 0x03 : 0;
                value |= _channels[3].active ? 0x04 : 0;
                return value;

                // TODO: if powered off, writes to registers are ignored, except for DMG
                // https://gbdev.gg8.se/wiki/articles/Gameboy_sound_hardware#Power_Control

            default:
                return 0xFF;
        }
    }

    public void writeIO(immutable ushort address, immutable ubyte data) {
        switch (address) {
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
        _cyclesPerSystemSample = (cast(double)_gameboy.clockRate / cast(double)systemSampleRate) / 2.0;

        // TODO: 0.998943 for MGB\CGB
        _highpassRate = pow(0.999958, cast(double)_gameboy.clockRate / cast(double)systemSampleRate);
        
        writefln("%06f cycles per system sample, %.08f highpass rate", _cyclesPerSystemSample, _highpassRate);
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