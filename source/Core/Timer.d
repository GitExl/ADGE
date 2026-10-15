module Core.Timer;

import std.stdio;

import Core.CPU;
import Core.IGameboyDevice;
import Core.Gameboy;


// TIMA increments on the falling edge of one bit of the system counter, selected by TAC.
// See https://gbdev.io/pandocs/Timer_Obscure_Behaviour.html
private immutable ushort[4] COUNTER_BITS = [1 << 9, 1 << 3, 1 << 5, 1 << 7];

private immutable ubyte CONTROL_ENABLE = 0x04;
private immutable ubyte CONTROL_SELECT = 0x03;
private immutable ubyte CONTROL_UNUSED_BITS = 0xF8;

private immutable ushort T_CYCLES_PER_M_CYCLE = 4;

// The CPU starts one M-cycle after the timer at power-on. Measured by DIV after each boot ROM.
private immutable ushort POWER_ON_COUNTER = T_CYCLES_PER_M_CYCLE;

// After TIMA overflows it reads 0 for one M-cycle, then reloads from TMA during the next.
private enum Reload {
    NONE,
    PENDING,
    RELOADING,
}

public final class Timer : IGameboyDevice {
    private CPU _cpu;

    // DIV is the upper byte of this counter.
    private ushort _systemCounter;

    private ubyte _counter;
    private ubyte _modulo;
    private ubyte _control;
    private Reload _reload;

    public void attach(Gameboy gameboy) {
        _cpu = gameboy.cpu;
    }

    public void reset() {
        _systemCounter = POWER_ON_COUNTER;

        _counter = 0;
        _modulo = 0;
        _control = 0;
        _reload = Reload.NONE;
    }

    public void cycle() {
        if (_reload == Reload.PENDING) {
            _counter = _modulo;
            _cpu.triggerInterrupt(InterruptFlag.TIMER);
            _reload = Reload.RELOADING;
        } else {
            _reload = Reload.NONE;
        }

        setSystemCounter(cast(ushort)(_systemCounter + T_CYCLES_PER_M_CYCLE), _control);
    }

    // Applies a new counter and control value, incrementing TIMA on a falling edge of the timer input.
    private void setSystemCounter(immutable ushort systemCounter, immutable ubyte control) {
        immutable bool before = timerInput(_systemCounter, _control);
        _systemCounter = systemCounter;
        _control = control;

        if (!before || timerInput(_systemCounter, _control)) {
            return;
        }

        _counter++;
        if (!_counter) {
            _reload = Reload.PENDING;
        }
    }

    private static bool timerInput(immutable ushort systemCounter, immutable ubyte control) {
        if (!(control & CONTROL_ENABLE)) {
            return false;
        }
        return (systemCounter & COUNTER_BITS[control & CONTROL_SELECT]) != 0;
    }

    @property
    public void divider(immutable ubyte value) {
        setSystemCounter(0, _control);
    }

    // The free running counter that DIV and the serial clock are divided from.
    @property
    public ushort systemCounter() {
        return _systemCounter;
    }

    @property
    public ubyte divider() {
        return _systemCounter >> 8;
    }

    @property
    public void counter(immutable ubyte value) {
        if (_reload == Reload.RELOADING) {
            return;
        }

        _counter = value;
        _reload = Reload.NONE;
    }

    @property ubyte counter() {
        return _counter;
    }

    @property
    public void modulo(immutable ubyte value) {
        _modulo = value;
        if (_reload == Reload.RELOADING) {
            _counter = value;
        }
    }

    @property
    public ubyte modulo() {
        return _modulo;
    }

    @property
    public void control(immutable ubyte value) {
        setSystemCounter(_systemCounter, value & ~CONTROL_UNUSED_BITS);
    }

    @property
    public ubyte control() {
        return _control | CONTROL_UNUSED_BITS;
    }
}

// Advances the timer by a number of M-cycles.
private void tick(Gameboy gameboy, immutable uint cycles) {
    foreach (i; 0 .. cycles) {
        gameboy.timer.cycle();
    }
}

// DIV increments every 256 T-cycles.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.timer.divider = 0;
    tick(gameboy, 63);
    assert(gameboy.timer.divider == 0);
    tick(gameboy, 1);
    assert(gameboy.timer.divider == 1);
}

// Writing DIV while the selected divider bit is set increments TIMA.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.timer.divider = 0;
    gameboy.timer.control = 0x05;
    tick(gameboy, 2);
    assert(gameboy.timer.counter == 0);
    gameboy.timer.divider = 0;
    assert(gameboy.timer.counter == 1);
}

// Disabling the timer while the selected divider bit is set increments TIMA.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.timer.divider = 0;
    gameboy.timer.control = 0x05;
    tick(gameboy, 2);
    gameboy.timer.control = 0x01;
    assert(gameboy.timer.counter == 1);
}

// TIMA reads 0 for one M-cycle after overflowing, then reloads from TMA and requests an interrupt.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.timer.divider = 0;
    gameboy.timer.modulo = 0x23;
    gameboy.timer.counter = 0xFF;
    gameboy.timer.control = 0x05;
    tick(gameboy, 4);
    assert(gameboy.timer.counter == 0);
    assert(!(gameboy.cpu.interruptFlags & InterruptFlag.TIMER));
    tick(gameboy, 1);
    assert(gameboy.timer.counter == 0x23);
    assert(gameboy.cpu.interruptFlags & InterruptFlag.TIMER);
}

// Writing TIMA in the M-cycle after overflow cancels the reload and interrupt.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.timer.divider = 0;
    gameboy.timer.modulo = 0x23;
    gameboy.timer.counter = 0xFF;
    gameboy.timer.control = 0x05;
    tick(gameboy, 4);
    gameboy.timer.counter = 0x42;
    tick(gameboy, 1);
    assert(gameboy.timer.counter == 0x42);
    assert(!(gameboy.cpu.interruptFlags & InterruptFlag.TIMER));
}

// In the reload M-cycle, TIMA writes are ignored and TMA writes also reach TIMA.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.timer.divider = 0;
    gameboy.timer.modulo = 0x23;
    gameboy.timer.counter = 0xFF;
    gameboy.timer.control = 0x05;
    tick(gameboy, 5);
    gameboy.timer.counter = 0x42;
    assert(gameboy.timer.counter == 0x23);
    gameboy.timer.modulo = 0x56;
    assert(gameboy.timer.counter == 0x56);
}

// The CPU starts one M-cycle after the timer at power-on, measured by DIV after each boot ROM.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    tick(gameboy, 62);
    assert(gameboy.timer.divider == 0);
    tick(gameboy, 1);
    assert(gameboy.timer.divider == 1);
}
