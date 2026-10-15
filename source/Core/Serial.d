module Core.Serial;

import Core.CPU;
import Core.Timer;
import Core.IGameboyDevice;
import Core.Gameboy;


private enum Control : ubyte {
    INTERNAL_CLOCK = 0x01,
    TRANSFER       = 0x80,
}

private immutable ubyte CONTROL_UNUSED_BITS = 0x7E;

// The internal 8192 Hz clock is divided from the system counter, so its edges align with power-on,
// not with the start of a transfer. Bits shift on its falling edge.
private immutable ushort CLOCK_BIT = 1 << 8;

private immutable uint TRANSFER_BITS = 8;

public final class Serial : IGameboyDevice {
    private CPU _cpu;
    private Timer _timer;

    private ubyte _data;
    private ubyte _control;
    private bool _clock;
    private uint _bitsShifted;

    public void attach(Gameboy gameboy) {
        _cpu = gameboy.cpu;
        _timer = gameboy.timer;
    }

    public void reset() {
        _data = 0;
        _control = 0;
        _clock = false;
        _bitsShifted = 0;
    }

    public void cycle() {
        immutable bool clock = (_timer.systemCounter & CLOCK_BIT) != 0;
        immutable bool fallingEdge = _clock && !clock;
        _clock = clock;

        // Externally clocked transfers wait for a partner that never comes.
        if (!fallingEdge || !(_control & Control.TRANSFER) || !(_control & Control.INTERNAL_CLOCK)) {
            return;
        }

        // Without a partner, 1 bits are shifted in.
        _data = cast(ubyte)((_data << 1) | 1);
        _bitsShifted++;
        if (_bitsShifted < TRANSFER_BITS) {
            return;
        }

        _control &= ~Control.TRANSFER;
        _cpu.triggerInterrupt(InterruptFlag.SERIAL);
    }

    @property
    public ubyte data() {
        return _data;
    }

    @property
    public void data(immutable ubyte value) {
        _data = value;
    }

    @property
    public ubyte control() {
        return _control | CONTROL_UNUSED_BITS;
    }

    @property
    public void control(immutable ubyte value) {
        _control = value & (Control.INTERNAL_CLOCK | Control.TRANSFER);
        _bitsShifted = 0;
    }
}

// The unused control bits read as 1.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    assert(gameboy.serial.control == 0x7E);
    gameboy.serial.control = 0x81;
    assert(gameboy.serial.control == 0xFF);
}

// Advances the timer and serial port by a number of M-cycles.
private void tickSerial(Gameboy gameboy, immutable uint cycles) {
    foreach (i; 0 .. cycles) {
        gameboy.timer.cycle();
        gameboy.serial.cycle();
    }
}

// An internally clocked transfer shifts a bit on each falling edge of the 8192 Hz clock, which is
// divided from the system counter. Without a partner, 1 bits are shifted in.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.timer.divider = 0;
    gameboy.serial.data = 0x00;
    gameboy.serial.control = 0x81;

    tickSerial(gameboy, 1023);
    assert(gameboy.serial.control == 0xFF);
    assert(gameboy.serial.data == 0x7F);
    assert(!(gameboy.cpu.interruptFlags & InterruptFlag.SERIAL));

    tickSerial(gameboy, 1);
    assert(gameboy.serial.control == 0x7F);
    assert(gameboy.serial.data == 0xFF);
    assert(gameboy.cpu.interruptFlags & InterruptFlag.SERIAL);
}

// An externally clocked transfer waits for a partner.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.serial.control = 0x80;
    tickSerial(gameboy, 2048);
    assert(gameboy.serial.control == 0xFE);
    assert(gameboy.serial.data == 0x00);
}
