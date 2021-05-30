module Core.Debugger;

import std.stdio;
import std.string;
import std.conv;

import core.stdc.stdlib;

import Core.CPU;
import Core.MMU;
import Core.LCD;
import Core.Cart;
import Core.IGameboyDevice;
import Core.Gameboy;
import Core.Disassembler;


public final class Debugger : IGameboyDevice {
    private CPU _cpu;
    private MMU _mmu;
    private LCD _lcd;
    private Cart _cart;
    private Disassembler _disasm;

    private bool _active;

    private ushort _breakpointAddress;
    private bool _isBreakpointEnabled;

    private bool _stepping = false;

    public this() {
    }

    public void attach(Gameboy gameboy) {
        _cpu = gameboy.cpu;
        _mmu = gameboy.mmu;
        _lcd = gameboy.lcd;
        _cart = gameboy.cart;

        _disasm = new Disassembler(_mmu);
    }

    public void reset() {
    }

    public void cycle() {
        if (_isBreakpointEnabled && _cpu.registers.PC == _breakpointAddress) {
            breakpoint();
        }

        if (_stepping) {
            _stepping = false;
            step();
        }
    }

    public void open() {
        writeln("Debugger active.");

        _active = true;
        while (_active) {
            writeln();
            write("> ");
            immutable string cmd = strip(stdin.readln());
            if (!cmd.length) {
                writeln("Resuming.");
                break;
            }

            string[] words = split(cmd);
            words[0] = words[0].toLower();
            switch (words[0]) {

                case "da":
                    ushort address = _cpu.registers.PC;
                    if (words.length > 1) {
                        address = getAddress(words[1]);
                    }
                    ushort length = 32;
                    if (words.length > 2) {
                        length = to!ushort(words[2]);
                    }
                    writefln("Disassembling %d instructions starting at $%04X.", length, address);
                    _disasm.disassemble(address, length);
                    break;

                case "state":
                    writeState();
                    break;

                case "lcd":
                    writeLCD();
                    break;

                case "oam":
                    writeOAM();
                    break;

                case "step":
                    _stepping = true;
                    writeln("Step.");
                    return;

                case "q":
                    writeln("Quitting.");
                    _cart.storeRAM();
                    exit(0);
                    return;

                case "dump":
                    string filename = "ram.bin";
                    if (words.length > 1) {
                        filename = words[1];
                    }
                    writefln("Writing memory to '%s'.", filename);
                    dump(filename);
                    break;

                case "bpr":
                    writeln("Removed breakpoint.");
                    _isBreakpointEnabled = false;
                    break;

                case "bp":
                    ushort address = _cpu.registers.PC;
                    if (words.length > 1) {
                        address = getAddress(words[1]);
                    }

                    writefln("Set breakpoint at $%04X.", address);
                    _isBreakpointEnabled = true;
                    _breakpointAddress = address;
                    break;

                case "stack":
                    uint count = 16;
                    if (words.length > 1) {
                        count = to!uint(words[1]);
                    }
                    
                    writefln("Dumping %d stack pointers.", count);
                    dumpStack(count);
                    break;

                default:
                    writeln("Unknown command.");
                    break;
            }
        }
    }

    public void breakpoint() {
        _disasm.disassemble(_cpu.registers.PC, 32);
        writeln("Breakpoint.");
        open();
    }

    public void step() {
        _disasm.disassemble(_cpu.registers.PC, 32);
        writeln("Stepped.");
        open();
    }

    private void dumpStack(immutable uint count) {
        ushort sp = _cpu.registers.SP;
        for (int i; i < count; i++) {
            writefln("$%04X: $%04X", sp, _mmu.read16(sp));
            sp += 2;
        }
    }

    private void writeState() {
        writefln("A: $%02X (%3d)   BC: $%04X (%5d)", _cpu.registers.A, _cpu.registers.A, _cpu.registers.BC, _cpu.registers.BC);
        writefln("B: $%02X (%3d)   DE: $%04X (%5d)", _cpu.registers.B, _cpu.registers.B, _cpu.registers.DE, _cpu.registers.DE);
        writefln("C: $%02X (%3d)   HL: $%04X (%5d)", _cpu.registers.C, _cpu.registers.C, _cpu.registers.HL, _cpu.registers.HL);
        writefln("D: $%02X (%3d)                  ", _cpu.registers.D, _cpu.registers.D);
        writefln("E: $%02X (%3d)   PC: $%04X (%5d)", _cpu.registers.E, _cpu.registers.E, _cpu.registers.PC, _cpu.registers.PC);
        writefln("H: $%02X (%3d)   SP: $%04X (%5d)", _cpu.registers.H, _cpu.registers.H, _cpu.registers.SP, _cpu.registers.SP);
        writefln("L: $%02X (%3d)                  ", _cpu.registers.L, _cpu.registers.L);
        writeln();
        writefln("Carry     : %d   Zero    : %d", (_cpu.registers.F & ALUFlag.CARRY) ? 1 : 0,      (_cpu.registers.F & ALUFlag.ZERO) ? 1 : 0);
        writefln("Half carry: %d   Subtract: %d", (_cpu.registers.F & ALUFlag.CARRY_HALF) ? 1 : 0, (_cpu.registers.F & ALUFlag.SUBTRACT) ? 1 : 0);
        writeln();
        writefln("IF: $%02X  IE: $%02X  IME: %d", _cpu.interruptFlags, _cpu.interruptsEnabled, _cpu.interruptsMasterEnable);
    }

    private void writeLCD() {
        writefln("Enabled: %d", cast(bool)(_lcd.control & 0x80));
        writefln("Mode: %d", _lcd.status & 0x3);
        writefln("BG: %d   WD: %d   OBJ: %d", cast(bool)(_lcd.control & 0x01), cast(bool)(_lcd.control & 0x20), cast(bool)(_lcd.control & 0x02));
        writefln("Tile GFX: $%04X   Background tilemap: $%04X   Window tilemap: $%04X", _lcd.addressTileGFX, _lcd.addressTilemapBG, _lcd.addressTilemapWindow);
    }

    private void writeOAM() {
        ushort offset = 0xFE00;
        for (int i = 0; i < 40; i++) {
            immutable ubyte y = _lcd.readOAMDirect(offset);
            immutable ubyte x = _lcd.readOAMDirect(cast(ushort)(offset + 1));
            immutable ubyte index = _lcd.readOAMDirect(cast(ushort)(offset + 2));
            immutable ubyte flags = _lcd.readOAMDirect(cast(ushort)(offset + 3));

            writefln("X: %03d  Y: %03d  Index: %03d  Flags: %08b", x, y, index, flags);

            offset += 4;
        }
    }

    public void dump(immutable string fileName) {
        ubyte[] data = new ubyte[0xFFFF];
        foreach (immutable ushort address; 0..0xFFFF) {
            data[address] = _mmu.read8(address);
        }

        File f = File(fileName, "wb");
        f.rawWrite(data);
        f.close();
    }

    private ushort getAddress(string data) {
        if (data.length > 2 && data[0] == '$') {
            string p = data[1..$];
            return parse!ushort(p, 16);
        }
        
        return parse!ushort(data);
    }
}