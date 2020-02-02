module Core.Timer;

import std.stdio;

import Core.CPU;
import Core.IGameboyDevice;
import Core.Gameboy;


private immutable double SGB_RATIO = 4295454.0 / 4194304.0;

private immutable double DIVIDER_RATE_GMB = 8192.0;
private immutable double DIVIDER_RATE_GBC = 16384.0;

private immutable double COUNTER_RATE_GMB_0 = 4096.0;
private immutable double COUNTER_RATE_GMB_1 = 262144.0;
private immutable double COUNTER_RATE_GMB_2 = 65536.0;
private immutable double COUNTER_RATE_GMB_3 = 16384.0;

private immutable double COUNTER_RATE_SGB_0 = COUNTER_RATE_GMB_0 * SGB_RATIO;
private immutable double COUNTER_RATE_SGB_1 = COUNTER_RATE_GMB_1 * SGB_RATIO;
private immutable double COUNTER_RATE_SGB_2 = COUNTER_RATE_GMB_2 * SGB_RATIO;
private immutable double COUNTER_RATE_SGB_3 = COUNTER_RATE_GMB_3 * SGB_RATIO;

public final class Timer : IGameboyDevice {
    private CPU _cpu;

    private ubyte _divider;
    private int _dividerCycles;
    private int _dividerTickCycles;

    private ubyte _counter;
    private ubyte _modulo;
    private ubyte _control;
    private int _counterCycles;
    private int _counterTickCycles;
    private bool _counterActive;
    private bool _triggerCounterWrap;

    private double _clockRate;

    public void attach(Gameboy gameboy) {
        _cpu = gameboy.cpu;
    }

    public void reset() {
        _divider = 0;
        _dividerCycles = 0;
        
        _counter = 0;
        _modulo = 0;
        _control = 0;
        _counterCycles = 0;
        _counterActive = false;

        updateTickCycles();
    }

    public void cycle() {

        // Update divider register.
        _dividerCycles += 4;
        if (_dividerCycles >= _dividerTickCycles) {
            _dividerCycles = 0;
            _divider++;
        }

        if (_counterActive) {

            // Bug: once the counter wraps it will be 0 for one cycle, after that it will be set
            // to modulo and trigger an interrupt.
            if (_triggerCounterWrap) {
                _counter = _modulo;
                _cpu.triggerInterrupt(InterruptFlag.TIMER);
                _triggerCounterWrap = false;
            }

            _counterCycles += 4;
            if (_counterCycles >= _counterTickCycles) {
                _counterCycles = 0;
                increaseCounter();
            }
        }
    }

    private void increaseCounter() {
        _counter++;
        if (_counter == 0) {
            _triggerCounterWrap = true;
        }
    }

    private void updateTickCycles() {
        _dividerTickCycles = cast(int)(_clockRate / DIVIDER_RATE_GMB);

        switch (_control & 0x3) {
            case 0: _counterTickCycles = cast(int)(_clockRate / COUNTER_RATE_GMB_0); break;
            case 1: _counterTickCycles = cast(int)(_clockRate / COUNTER_RATE_GMB_1); break;
            case 2: _counterTickCycles = cast(int)(_clockRate / COUNTER_RATE_GMB_2); break;
            case 3: _counterTickCycles = cast(int)(_clockRate / COUNTER_RATE_GMB_3); break;
            default:
                throw new Exception("Unhandled timer counter bits.");
        }
    }

    public void updateClockRate(immutable double rate) {
        _clockRate = rate;
        updateTickCycles();
    }

    @property
    public void divider(immutable ubyte value) {

        // Bug: TIMA increases when the counter is active, set to 1 and is reset to 0 by writing to it.
        if (_counterActive && _divider == 1) {
            increaseCounter();
        }
        
        _divider = 0;
    }

    @property
    public ubyte divider() {
        return _divider;
    }

    @property
    public void counter(immutable ubyte value) {
        if (!_triggerCounterWrap) {
            _counter = value;
        }
        
        _triggerCounterWrap = false;
    }

    @property ubyte counter() {
        return _counter;
    }

    @property
    public void modulo(immutable ubyte value) {
        _modulo = value;
    }

    @property
    public ubyte modulo() {
        return _modulo;
    }

    @property
    public void control(immutable ubyte value) {
        _control = value;

        // Update counter state.
        if (_control & 0x4) {
            _counterActive = true;
        } else {
            _counterActive = false;
        }
        
        updateTickCycles();
    }

    @property
    public ubyte control() {
        return _control;
    }
}