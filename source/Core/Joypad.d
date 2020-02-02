module Core.Joypad;

import std.stdio;

import Core.CPU;
import Core.IGameboyDevice;
import Core.Gameboy;


private enum JoypadFlagButtons : ubyte {
    START  = 0x08,
    SELECT = 0x04,
    B      = 0x02,
    A      = 0x01,
}

private enum JoypadFlagDirections : ubyte {
    DOWN  = 0x08,
    UP    = 0x04,
    LEFT  = 0x02,
    RIGHT = 0x01,
}

private enum Mode : ubyte {
    NONE      = 0x00,
    BUTTONS   = 0x10,
    DIRECTION = 0x20,
}

public enum Key : ubyte {
    UP,
    DOWN,
    LEFT,
    RIGHT,
    A,
    B,
    START,
    SELECT,
}

public final class Joypad : IGameboyDevice {
    private Gameboy _gameboy;
    private CPU _cpu;

    private bool[8] _keyStates;
    private Mode _readMode;

    public void attach(Gameboy gameboy) {
        _gameboy = gameboy;
        _cpu = gameboy.cpu;
    }

    public void reset() {
        _keyStates[] = false;
        _readMode = Mode.NONE;
    }

    public void cycle() {
    }

    public void setKeyState(immutable Key key, immutable bool state) {
        _keyStates[key] = state;
        
        // Any keypress disables the CPU STOP state.
        if (state && _cpu.state == State.STOPPED) {
            _cpu.exitStop();
        }

        // Trigger joypad interrupts for non-CGB devices.
        if (_gameboy.mode != GameboyMode.COLOR) {
            if (_readMode == Mode.DIRECTION) {
                if (key == Key.UP || key == Key.DOWN || key == Key.LEFT || key == Key.RIGHT) {
                    _cpu.triggerInterrupt(InterruptFlag.JOYPAD);
                }
            } else if (_readMode == Mode.BUTTONS) {
                if (key == Key.A || key == Key.B || key == Key.START || key == Key.SELECT) {
                    _cpu.triggerInterrupt(InterruptFlag.JOYPAD);
                }
            }
        }
    }

    @property
    public ubyte status() {
        ubyte value = 0xF;

        if (_readMode & Mode.DIRECTION) {
            if (_keyStates[Key.DOWN])  value &= ~cast(int)JoypadFlagDirections.DOWN;
            if (_keyStates[Key.UP])    value &= ~cast(int)JoypadFlagDirections.UP;
            if (_keyStates[Key.LEFT])  value &= ~cast(int)JoypadFlagDirections.LEFT;
            if (_keyStates[Key.RIGHT]) value &= ~cast(int)JoypadFlagDirections.RIGHT;
        } else if (_readMode & Mode.BUTTONS) {
            if (_keyStates[Key.START])  value &= ~cast(int)JoypadFlagButtons.START;
            if (_keyStates[Key.SELECT]) value &= ~cast(int)JoypadFlagButtons.SELECT;
            if (_keyStates[Key.A])      value &= ~cast(int)JoypadFlagButtons.A;
            if (_keyStates[Key.B])      value &= ~cast(int)JoypadFlagButtons.B;
        }

        return value;
    }

    @property
    public void status(immutable ubyte value) {
        _readMode = cast(Mode)(value & 0x30);
    }
}