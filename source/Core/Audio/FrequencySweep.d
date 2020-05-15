module Core.Audio.FrequencySweep;

import Core.Audio.IChannel;
import Core.Audio.SquareWave;


public class FrequencySweep {
    private IChannel _channel;
    private SquareWave _squareWave;

    private int _tick;
    private int _shift;
    private bool _negative;
    private int _tempo;
    private ushort _shadow;
    private bool _enabled;
    private int _countdown;
    private int _overflowDelay;
    private ushort _newFrequency;
    
    public this(IChannel channel, SquareWave squareWave) {
        _channel = channel;
        _squareWave = squareWave;
    }

    public void reset() {
        _tick = 2;
        _shift = 0;
        _negative = false;
        _tempo = 0;
        _shadow = 0;
        _enabled = false;
        _countdown = 0;
        _overflowDelay = 0;
    }

    public void trigger() {

        // Ticking starts at 4, halfway through 8 total ticks.
        _tick = 4;

        _countdown = _tempo;
        _enabled = _shift && _tempo;
        _shadow = _squareWave.frequency;
        _newFrequency = _squareWave.frequency;
        _overflowDelay = 0;

        // If shifting, immediately calculate the new frequency and check it for overflow.
        if (_shift) {
            updateShadowFrequency();
            if (_shadow > 0x7FF) {
                _channel.stop();
                _enabled = false;
            } else {
                _squareWave.frequency = _shadow;
            }
        }
    }

    public void cycle() {

        // Bug: check new sweep frequency overflow after setting it earlier.
        if (_overflowDelay) {
            _overflowDelay--;
            if (_overflowDelay == 0) {
                updateShadowFrequency();
                if (_shadow > 0x7FF) {
                    _channel.stop();
                    _enabled = false;
                }
            }
        }
    }

    public void frame() {

        if (!_tick) {
            _tick = 4;

            if (_enabled) {
                if (!_countdown) {
                    _countdown = _tempo;

                    updateShadowFrequency();
                    if (_shadow > 0x7FF) {
                        _channel.stop();
                        _enabled = false;
                    } else {
                        _squareWave.frequency = _shadow;
                    }

                    // Bug: recalculate sweep overflow again later.
                    // TODO: what is correct timing? This is 8 cycles (2 * 4 clocks).
                    _overflowDelay = 2;
                }
                _countdown--;
            }
        }
        _tick--;
    }

    private void updateShadowFrequency() {
        immutable int delta = _shadow >> _shift;
        if (_negative) {
            _shadow -= delta;
        } else {
            _shadow += delta;
        }
    }

    @property
    public int shift() {
        return _shift;
    }

    @property
    public void shift(immutable int newShift) {
        _shift = newShift;
    }

    @property
    public bool negative() {
        return _negative;
    }

    @property
    public void negative(immutable bool newNegative) {
        _negative = newNegative;
    }

    @property
    public int tempo() {
        return _tempo;
    }

    @property
    public void tempo(immutable int newTempo) {
        _tempo = newTempo;
    }

}
