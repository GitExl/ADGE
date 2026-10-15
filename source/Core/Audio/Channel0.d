module Core.Audio.Channel0;

import std.stdio;

import Core.MMU;

import Core.Audio.ChannelBase;
import Core.Audio.FrequencySweep;
import Core.Audio.SquareWave;
import Core.Audio.VolumeEnvelope;
import Core.Audio.Duration;


public final class Channel0 : ChannelBase {
    private ushort _frameTicks;
    private FrequencySweep _frequencySweep;
    private SquareWave _squareWave;
    private VolumeEnvelope _volumeEnvelope;
    private Duration _duration;

    public this() {
        _squareWave = new SquareWave();
        _frequencySweep = new FrequencySweep(this, _squareWave);
        _volumeEnvelope = new VolumeEnvelope(this);
        _duration = new Duration(this, 64);
    }

    public void reset() {
        _frameTicks = 0;
        _active = false;
        _volume = 1;
        
        _frequencySweep.reset();
        _squareWave.reset();
        _volumeEnvelope.reset();
        _duration.reset();
    }

    public double cycle() {
        _frequencySweep.cycle();

        // Frame sequencer.
        if (!_frameTicks) {
            _frameTicks = 4096;

            _frequencySweep.frame();
            _duration.frame();
            _volumeEnvelope.frame();
        }
        _frameTicks--;

        _squareWave.cycle();
        if (_active) {
            return _squareWave.sample() * (_volume * (1.0 / 15.0));
        } else {
            return 0.0;
        }
    }

    public void writeIO(immutable ushort address, immutable ubyte data) {
        switch (address) {
            case IO.SND10:
                _frequencySweep.shift = data & 0x07;
                _frequencySweep.negative = cast(bool)(data & 0x08);
                _frequencySweep.tempo = (data >> 4) & 0x07;
                break;

            case IO.SND11:
                _duration.length = data & 0x3F;
                _squareWave.duty = (data >> 6) & 0x03;
                break;

            case IO.SND12:
                if (!(data & 0xF8)) {
                    _active = false;
                    _squareWave.resetStep();
                }
                _volumeEnvelope.length = data & 0x07;
                _volumeEnvelope.negative = !cast(bool)(data & 0x08);
                _volumeEnvelope.initial = (data >> 4) & 0x0F;
                break;

            case IO.SND13:
                _squareWave.frequency = (_squareWave.frequency & 0xFF00) | data;
                break;

            case IO.SND14:
                _squareWave.frequency = (_squareWave.frequency & 0x00FF) | (data & 0x07) << 8;
                _duration.stop = cast(bool)(data & 0x40);

                if (data & 0x80) {
                    _active = true;

                    _duration.trigger();
                    _squareWave.trigger();
                    _frequencySweep.trigger();
                    _volumeEnvelope.trigger();
                }
                break;

            default:
                break;
        }
    }
}
