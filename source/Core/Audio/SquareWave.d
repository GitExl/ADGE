module Core.Audio.SquareWave;


private static immutable double[][] WAVEFORMS = [
    [-1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0,  1.0],
    [ 1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0,  1.0],
    [ 1.0, -1.0, -1.0, -1.0, -1.0,  1.0,  1.0,  1.0],
    [-1.0,  1.0,  1.0,  1.0,  1.0,  1.0,  1.0, -1.0],
];

public class SquareWave {
    private int _duty;
    private int _ticks;
    private int _step;
    private ushort _frequency;
    private bool _enabled;

    public void reset() {
        _duty = 0;
        _ticks = 0;
        _step = 0;
        _frequency = 0;
        _enabled = false;
    }

    public void trigger() {
        _ticks = (2048 - _frequency) * 2;
        _enabled = true;
    }

    public void cycle() {
        if (!_enabled) {
            return;
        }

        if (!_ticks) {
            _ticks = (2048 - _frequency) * 2;
            _step = (_step + 1) % 8;
        }
        _ticks--;
    }

    public double sample() {
        return WAVEFORMS[_duty][_step];
    }

    public void resetStep() {
        _step = 0;
    }

    @property
    public ushort frequency() {
        return _frequency;
    }

    @property
    public void frequency(immutable ushort newFrequency) {
        _frequency = newFrequency;
    }

    @property
    public int duty() {
        return _duty;
    }

    @property
    public void duty(immutable int newDuty) {
        _duty = newDuty;
    }
}