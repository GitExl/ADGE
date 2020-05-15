module Core.Audio.Channel3;

import std.stdio;

import Core.Audio.ChannelBase;

import Core.Audio.Duration;
import Core.Audio.VolumeEnvelope;

import Core.MMU;


public final class Channel3 : ChannelBase {
    private int _frameTicks;

    private int _shiftTicks;
    private ubyte _shiftFrequency;
    private ubyte _shiftDivisor;
    private bool _isNarrow;
    private ubyte _currentSample;
    private int _shiftRegister;

    private Duration _duration;
    private VolumeEnvelope _volumeEnvelope;

    public this() {
        _frameTicks = 0;
        _active = false;
        _volume = 1;

        _shiftFrequency = 0;
        _shiftTicks = 0;
        _isNarrow = false;
        _shiftDivisor = 0;

        _volumeEnvelope = new VolumeEnvelope(this);
        _duration = new Duration(this, 64);
    }

    public void reset() {
        _volumeEnvelope.reset();
        _duration.reset();
    }

    public double cycle() {

        // Frame sequencer.
        if (!_frameTicks) {
            _frameTicks = 4096;

            _duration.frame();
            _volumeEnvelope.frame();
        }
        _frameTicks--;

        if (!_shiftTicks) {
            _shiftTicks = ((_shiftDivisor << _shiftFrequency) - 1) * 2;

            immutable int bitMask = _isNarrow ? 0x4040 : 0x4000;
            immutable bool bit = (_shiftRegister ^ (_shiftRegister >> 1) ^ 1) & 1;
            _shiftRegister >>= 1;

            if (bit) {
                _shiftRegister |= bitMask;
            } else {
                _shiftRegister &= ~bitMask;
            }
            _currentSample = _shiftRegister & 1;
        }
        _shiftTicks--;

        if (_active) {
            return (_currentSample ? 1.0 : -1.0) * (_volume * (1.0 / 15.0));
        } else {
            return 0.0;
        }
    }

    public ubyte readIO(immutable ushort address) {
        switch (address) {
            case IO.SND42:
                ubyte value;
                value = _volumeEnvelope.length;
                value |= _volumeEnvelope.negative ? 0 : 0x08;
                value |= _volumeEnvelope.initial << 4;
                return value;

            case IO.SND44:
                return _duration.stop ? 0x40 : 0;

            default:
                return 0xFF;
        }
    }

    public void writeIO(immutable ushort address, immutable ubyte data) {
        switch (address) {
            case IO.SND41:
                _duration.length = data & 0x3F;
                break;

            case IO.SND42:
                if (!(data & 0xF8)) {
                    _active = false;
                }
                _volumeEnvelope.length = data & 0x07;
                _volumeEnvelope.negative = !cast(bool)(data & 0x08);
                _volumeEnvelope.initial = (data >> 4) & 0x0F;
                break;

            case IO.SND43:
                _isNarrow = cast(bool)(data & 0x08);
                _shiftFrequency = (data & 0xF0) >> 4;
                _shiftDivisor = (data & 0x07) << 1;
                if (_shiftDivisor == 0) {
                    _shiftDivisor = 1;
                }
                break;

            case IO.SND44:
                _duration.stop = cast(bool)(data & 0x40);

                if (data & 0x80) {
                    _active = true;

                    _shiftTicks = ((_shiftDivisor << _shiftFrequency) - 1) * 2;
                    _currentSample = 0;
                    _shiftRegister = 0;

                    _duration.trigger();
                    _volumeEnvelope.trigger();
                }
                break;

            default:
                break;
        }
    }
}
