module Core.Audio.Duration;

import Core.Audio.IChannel;


public class Duration {
    private IChannel _channel;
    private int _max;

    private int _length;
    private int _lengthTick;
	private bool _stop;

    public this(IChannel channel, immutable int max) {
        _channel = channel;
        _max = max;
    }

    public void reset() {
        _length = 0;
        _lengthTick = 0;
        _stop = false;
    }

    public void frame() {
        if (!_lengthTick) {
            _lengthTick = 2;

            if (_stop && _length) {
                _length--;
                if (!_length) {
                    _channel.stop();
                }
            }
        }
        _lengthTick--;
    }

    public void trigger() {
        if (_length == 0) {
            _length = _max;
            _stop = false;
        }
    }

    @property
    public void length(immutable int newLength) {
        _length = _max - newLength;
    }

    @property
    public int length() {
        return _length;
    }

    @property
    public void stop(immutable bool newStop) {
        _stop = newStop;
    }

    @property
    public bool stop() {
        return _stop;
    }
}