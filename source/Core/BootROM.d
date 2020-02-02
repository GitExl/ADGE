module Core.BootROM;

import std.stdio;
import std.file;

import Core.IGameboyDevice;
import Core.Gameboy;


public class BootROM : IGameboyDevice {
    private ubyte[] _rom;

    public this(string bootROM) {
        _rom = cast(ubyte[])read(bootROM);
    }

    public void reset() {
    }

    public ubyte read8(immutable ushort address) {
        return _rom[address];
    }

    public void attach(Gameboy gameboy) {
    }

    public void cycle() {
    }

    @property
    public int size() {
        return cast(int)_rom.length;
    }
}
