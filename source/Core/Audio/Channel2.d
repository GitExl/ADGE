module Core.Audio.Channel2;

import std.stdio;

import Core.MMU;

import Core.Audio.ChannelBase;
import Core.Audio.Duration;


private immutable ubyte[] VOLUME_SHIFT = [4, 0, 1, 2];

public final class Channel2 : ChannelBase {
	
    private ushort _frameTicks;

    private ubyte[16] _samples;
    private ubyte _sampleIndex;
    private ubyte _sampleBuffer;
    private int _sampleTick;
    private bool _waveFormRead;

	private ushort _frequency;
    private ubyte _volumeShift;

    private Duration _duration;

    public this() {
        _duration = new Duration(this, 256);
    }

	public void reset() {
        _frameTicks = 0;

        // Should be mostly random, this is just one possible set.
        // For GBC this is always 00 FF 00 FF 00 FF 00 FF 00 FF 00 FF 00 FF 00 FF
        _samples = [0x84, 0x40, 0x43, 0xAA, 0x2D, 0x78, 0x92, 0x3C, 0x60, 0x59, 0x59, 0xB0, 0x34, 0xB8, 0x2E, 0xDA];

        _sampleIndex = 0;
        _sampleBuffer = 0;
        _sampleTick = 0;
        _waveFormRead = false;

        _frequency = 0;
        _volumeShift = VOLUME_SHIFT[_volume];

        _duration.reset();
	}

	public double cycle() {

        // Frame sequencer.
        if (!_frameTicks) {
            _frameTicks = 4096;

            _duration.frame();
        }
        _frameTicks--;

        _waveFormRead = false;
        if (!_sampleTick) {
            _sampleTick = (2048 - _frequency);

            _sampleIndex = (_sampleIndex + 1) & 0x1F;
            _sampleBuffer = _samples[_sampleIndex >> 1];
            _waveFormRead = true;
        }
        _sampleTick--;

        if (_active) {
            immutable ubyte nibble = _sampleIndex % 2;
            immutable ubyte sampleByte = nibble ? _sampleBuffer & 0xF : (_sampleBuffer & 0xF0) >> 4;
            return cast(double)(sampleByte >> _volumeShift) * (2.0 / 15.0) - 1.0;
        }

        return 0.0;
	}

    public ubyte readIO(immutable ushort address) {
        switch (address) {
            case IO.SND30:
                return _active ? 0x40 : 0;

            case IO.SND34:
                return _duration.stop ? 0x40 : 0;

            default:
                return 0xFF;
        }
    }

    public void writeIO(immutable ushort address, immutable ubyte data) {
        switch (address) {
            case IO.SND30:
                _active = cast(bool)(data & 0x80);
                break;

            case IO.SND31:
                _duration.length = data;
                break;

            case IO.SND32:
                _volume = (data >> 5) & 0x3;
                _volumeShift = VOLUME_SHIFT[_volume];
                break;

            case IO.SND33:
                _frequency = (_frequency & 0xFF00) | data;
                break;

            case IO.SND34:
                _frequency = (_frequency & 0x00FF) | (data & 0x07) << 8;
                _duration.stop = cast(bool)(data & 0x40);

                if (data & 0x80) {
                    _sampleIndex = 0;
                    _sampleTick = (2048 - _frequency);

                    _duration.trigger();

                    _active = true;
                }
                break;

            default:
                break;
        }
    }

    public ubyte readWave(immutable ushort address) {

        // Quirk: If the wave channel is enabled, accessing any byte from $FF30-$FF3F is equivalent
        // to accessing the current byte selected by the waveform position. Further, on the DMG
        // accesses will only work in this manner if made within a couple of clocks of the wave
        // channel accessing wave RAM; if made at any other time, reads return $FF and writes have
        // no effect.
        // TODO: not for CGB
        if (_active) {
            if (_waveFormRead) {
                return _sampleBuffer;
            }
            return 0xFF;
        }

        return _samples[(address - IO.SND_WAVE_START) & 0xF];
    }

    public void writeWave(immutable ushort address, immutable ubyte data) {

        // Quirk: If the wave channel is enabled, accessing any byte from $FF30-$FF3F is equivalent
        // to accessing the current byte selected by the waveform position. Further, on the DMG
        // accesses will only work in this manner if made within a couple of clocks of the wave
        // channel accessing wave RAM; if made at any other time, reads return $FF and writes have
        // no effect.
        // TODO: not for CGB
        if (_active && _waveFormRead) {
            return;
        }

        _samples[(address - IO.SND_WAVE_START) & 0xF] = data;
    }
}
