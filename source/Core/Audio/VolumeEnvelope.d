module Core.Audio.VolumeEnvelope;

import Core.Audio.IChannel;


public class VolumeEnvelope {
    private IChannel _channel;

    private int _tick;
    private ubyte _initial;
    private ubyte _length;
    private bool _negative;
    private int _counter;

    public this(IChannel channel) {
        _channel = channel;
    }

    public void reset() {
        _tick = 7;
        _initial = 1;
        _length = 0;
        _negative = false;
        _counter = 0;
    }

    public void trigger() {
        _tick = 14;
        _counter = _length;

        _channel.volume = _initial;
    }

    public void frame() {
        if (!_tick) {
            _tick = 8;

            immutable ubyte currentVolume = _channel.volume;
            if (_length && (currentVolume > 0 || currentVolume < 15)) {
                if (!_counter) {
                    _counter = _length;

                    if (_negative && currentVolume > 0) {
                        _channel.volume = cast(ubyte)(currentVolume - 1);
                    } else if (!_negative && currentVolume < 15) {
                        _channel.volume = cast(ubyte)(currentVolume + 1);
                    }
                }
                _counter--;
            }
        }
        _tick--;
    }

    @property
    public ubyte length() {
        return _length;
    }

    @property
    public void length(immutable ubyte newLength) {
        if (_length && ! newLength) {
            _channel.stop();
        }
        _length = newLength;
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
    public ubyte initial() {
        return _initial;
    }

    @property
    public void initial(immutable ubyte newInitial) {
        _initial = newInitial;
    }

}