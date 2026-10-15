module Core.Cart;

import std.stdio;
import std.string;
import std.file;
import std.path;

import Core.MBC.IMBC;
import Core.MBC.MBCNone;
import Core.MBC.MBC1;
import Core.MBC.MBC2;
import Core.MBC.MBC3;
import Core.MBC.MBC5;

import Core.IGameboyDevice;
import Core.Gameboy;


private enum Hardware : ubyte {
    RAM     = 0x01,
    BATTERY = 0x02,
    TIMER   = 0x04,
    RUMBLE  = 0x08,
    CAMERA  = 0x10,
}

private immutable uint ROM_BANK_SIZE = 0x4000;
private immutable uint RAM_BANK_SIZE = 0x2000;

// MBC1 multicarts are 8 Mbit, holding games of 256 KiB each, each with its own header.
private immutable size_t MULTICART_SIZE = 0x100000;
private immutable size_t MULTICART_GAME_BANK = 0x10;
private immutable size_t LOGO_START = 0x0104;
private immutable size_t LOGO_END = 0x0134;

public final class Cart : IGameboyDevice {
    private ubyte[] _rom;
    private ubyte[] _ram;
    private string _ramFileName;
    private ubyte _ramMask;

    private string _title;
    private string _licensee;
    
    private bool _isCGB;
    private bool _isCGBOnly;
    private bool _isSGB;
    private bool _isNonJapanese;

    private IMBC _mbc;
    private Hardware _hardware;
    private uint _sizeROM;

    private ubyte _maskVersion;
    private ubyte _checksumHeader;
    private ushort _checksumGlobal;

    public void attach(Gameboy game) {
    }

    public void reset() {
        if (_mbc !is null) {
            _mbc.reset();
        }
    }

    public void cycle() {
    }

    public void load(immutable string fileName) {
        if (!exists(fileName)) {
            throw new Exception(format("Cartridge file '%s' does not exist.", fileName));
        }

        _rom = cast(ubyte[])read(fileName);
        
        _isCGB = (_rom[0x0143] != 0);
        _isCGBOnly = cast(bool)(_rom[0x0143] & 0x40);
        _isSGB = (_rom[0x0146] == 0x03);
        _isNonJapanese = (_rom[0x014A] == 0x1);

        _maskVersion = _rom[0x014C];
        _checksumHeader = _rom[0x014D];
        _checksumGlobal = _rom[0x014E] | (_rom[0x014F] >> 8);
        
        switch (_rom[0x0149]) {
            case 0x00: _ram.length = 0x00000; break;
            case 0x01: _ram.length = 0x00800; break;
            case 0x02: _ram.length = 0x02000; break;
            case 0x03: _ram.length = 0x08000; break;
            case 0x04: _ram.length = 0x20000; break;
            case 0x05: _ram.length = 0x10000; break;
            default:
                throw new Exception("Invalid cartridge RAM size.");
        }

        switch (_rom[0x0148]) {
            case 0x00: _sizeROM = 0x4000 * 2; break;
            case 0x01: _sizeROM = 0x4000 * 4; break;
            case 0x02: _sizeROM = 0x4000 * 8; break;
            case 0x03: _sizeROM = 0x4000 * 16; break;
            case 0x04: _sizeROM = 0x4000 * 32; break;
            case 0x05: _sizeROM = 0x4000 * 64; break;
            case 0x06: _sizeROM = 0x4000 * 128; break;
            case 0x07: _sizeROM = 0x4000 * 256; break;
            case 0x08: _sizeROM = 0x4000 * 512; break;
            case 0x52: _sizeROM = 0x4000 * 72; break;
            case 0x53: _sizeROM = 0x4000 * 80; break;
            case 0x54: _sizeROM = 0x4000 * 96; break;
            default:
                throw new Exception("Invalid cartridge ROM size.");
        }

        _ramMask = 0xFF;
        switch (_rom[0x0147]) {
            case 0x00: _mbc = new MBCNone(); _hardware = cast(Hardware)(0); break;
            case 0x01: _mbc = new MBC1(mbc1Wiring()); _hardware = cast(Hardware)(0); break;
            case 0x02: _mbc = new MBC1(mbc1Wiring()); _hardware = cast(Hardware)(Hardware.RAM); break;
            case 0x03: _mbc = new MBC1(mbc1Wiring()); _hardware = cast(Hardware)(Hardware.RAM | Hardware.BATTERY); break;
            case 0x05: _mbc = new MBC2(); _hardware = cast(Hardware)(Hardware.RAM); _ramMask = 0x0F; _ram.length = 512; break;
            case 0x06: _mbc = new MBC2(); _hardware = cast(Hardware)(Hardware.RAM | Hardware.BATTERY); _ramMask = 0x0F; _ram.length = 512; break;
            case 0x08: _mbc = new MBCNone(); _hardware = cast(Hardware)(Hardware.RAM); break;
            case 0x09: _mbc = new MBCNone(); _hardware = cast(Hardware)(Hardware.RAM | Hardware.BATTERY); break;
            //case 0x0B: _mbc = MBC.MMM01; _hardware = cast(Hardware)(0); break;
            //case 0x0C: _mbc = MBC.MMM01; _hardware = cast(Hardware)(Hardware.RAM); break;
            //case 0x0D: _mbc = MBC.MMM01; _hardware = cast(Hardware)(Hardware.RAM | Hardware.BATTERY); break;
            case 0x0F: _mbc = new MBC3(); _hardware = cast(Hardware)(Hardware.TIMER | Hardware.BATTERY); break;
            case 0x10: _mbc = new MBC3(); _hardware = cast(Hardware)(Hardware.TIMER | Hardware.RAM | Hardware.BATTERY); break;
            case 0x11: _mbc = new MBC3(); _hardware = cast(Hardware)(0); break;
            case 0x12: _mbc = new MBC3(); _hardware = cast(Hardware)(Hardware.RAM); break;
            case 0x13: _mbc = new MBC3(); _hardware = cast(Hardware)(Hardware.RAM | Hardware.BATTERY); break;
            case 0x19: _mbc = new MBC5(); _hardware = cast(Hardware)(0); break;
            case 0x1A: _mbc = new MBC5(); _hardware = cast(Hardware)(Hardware.RAM); break;
            case 0x1B: _mbc = new MBC5(); _hardware = cast(Hardware)(Hardware.RAM | Hardware.BATTERY); break;
            case 0x1C: _mbc = new MBC5(); _hardware = cast(Hardware)(Hardware.RUMBLE); break;
            case 0x1D: _mbc = new MBC5(); _hardware = cast(Hardware)(Hardware.RUMBLE | Hardware.RAM); break;
            case 0x1E: _mbc = new MBC5(); _hardware = cast(Hardware)(Hardware.RUMBLE | Hardware.RAM | Hardware.BATTERY); break;
            case 0xFC: _mbc = new MBCNone(); _hardware = cast(Hardware)(Hardware.CAMERA); break;
            //case 0xFD: _mbc = MBC.TAMA5; _hardware = cast(Hardware)(0); break;
            //case 0xFE: _mbc = MBC.HUC3; _hardware = cast(Hardware)(0); break;
            //case 0xFF: _mbc = MBC.HUC1; _hardware = cast(Hardware)(Hardware.RAM | Hardware.BATTERY); break;
            default:
                throw new Exception("Invalid or unsupported cartridge type.");
        }

        _mbc.reset();

        writefln("MBC: %s", _mbc.name);
        writefln("RAM: %s", (_hardware & Hardware.RAM) ? format("yes, %d bytes", _ram.length) : "no");
        writefln("Battery: %s", (_hardware & Hardware.BATTERY) ? "yes" : "no");
        writefln("Timer: %s", (_hardware & Hardware.TIMER) ? "yes" : "no");
        writefln("Rumble: %s", (_hardware & Hardware.RUMBLE) ? "yes" : "no");

        if (_isCGB) {
            _title = strip(cast(string)_rom[0x0134..0x013F]);
        } else {
            _title = strip(cast(string)_rom[0x0134..0x0142]);
        }
        if (_rom[0x014B] == 0x33) {
            _licensee = strip(cast(string)_rom[0x0144..0x0145]);
        } else {
            _licensee = strip(cast(string)_rom[0x014B..0x014B]);
        }

        _ramFileName = stripExtension(fileName) ~ ".ram";
        restoreRAM();
    }

    public ubyte readROM(immutable ushort address) {
        immutable size_t banks = _rom.length / ROM_BANK_SIZE;
        if (address < 0x4000) {
            return _rom[(_mbc.lowRomBank % banks) * ROM_BANK_SIZE + address];
        }

        immutable size_t bank = _mbc.romBank % banks;
        return _rom[bank * ROM_BANK_SIZE + (address - 0x4000)];
    }

    // Multicarts have no header flag. Detected by the Nintendo logo repeating in the second game's header.
    private Wiring mbc1Wiring() {
        if (_rom.length != MULTICART_SIZE) {
            return Wiring.STANDARD;
        }

        immutable size_t game = MULTICART_GAME_BANK * ROM_BANK_SIZE;
        if (_rom[game + LOGO_START .. game + LOGO_END] != _rom[LOGO_START .. LOGO_END]) {
            return Wiring.STANDARD;
        }

        return Wiring.MULTICART;
    }

    public void writeROM(immutable ushort address, immutable ubyte value) {
        _mbc.write(address, value);
    }

    public ubyte readRAM(immutable ushort address) {
        if (!(_hardware & Hardware.RAM) || !_ram.length) {
            return 0;
        }
        if (!_mbc.ramEnabled) {
            return 0xFF;
        }
        
        // Bits missing from the RAM chip read as 1.
        return cast(ubyte)(_ram[ramOffset(address)] | ~_ramMask);
    }

    public void writeRAM(immutable ushort address, immutable ubyte value) {
        if (!(_hardware & Hardware.RAM) || !_ram.length) {
            return;
        }
        if (!_mbc.ramEnabled) {
            return;
        }

        _ram[ramOffset(address)] = value & _ramMask;
    }

    // RAM sizes are powers of 2, so this wraps both out of range banks and
    // RAM smaller than a bank, like MBC2's 512 bytes repeating across A000-BFFF.
    private size_t ramOffset(immutable ushort address) {
        return (_mbc.ramBank * RAM_BANK_SIZE + (address - 0xA000)) % _ram.length;
    }

    public void storeRAM() {
        if (!(_hardware & Hardware.RAM) || !_ram.length || !(_hardware & Hardware.BATTERY)) {
            return;
        }

        std.file.write(_ramFileName, _ram);
        writefln("Stored cartridge RAM.");
    }

    public void restoreRAM() {
        if (!(_hardware & Hardware.RAM) || !_ram.length || !(_hardware & Hardware.BATTERY)) {
            return;
        }
        if (!exists(_ramFileName)) {
            return;
        }

        _ram = cast(ubyte[])read(_ramFileName);
        writefln("Restored cartridge RAM.");
    }

    @property
    public string title() {
        return _title;
    }

    @property
    public string licensee() {
        return _licensee;
    }

    @property
    public bool isCGB() {
        return _isCGB;
    }

    @property
    public bool isCGBOnly() {
        return _isCGBOnly;
    }

    @property
    public bool isSGB() {
        return _isSGB;
    }
}
// Bank numbers beyond the ROM size wrap, as unconnected bank lines are ignored.
unittest {
    import Core.MBC.MBC5;

    Cart cart = new Cart();
    cart._rom.length = 0x4000 * 4;
    foreach (ubyte bank; 0 .. 4) {
        cart._rom[bank * 0x4000] = bank;
    }
    cart._mbc = new MBC5();
    cart._mbc.reset();

    cart.writeROM(0x2000, 0x06);
    cart.writeROM(0x3000, 0x01);
    assert(cart.readROM(0x4000) == 2);
}

// RAM bank numbers wrap too. On rumble carts, bit 3 of the RAM bank is the motor.
unittest {
    import Core.MBC.MBC5;

    Cart cart = new Cart();
    cart._hardware = Hardware.RAM;
    cart._ramMask = 0xFF;
    cart._ram.length = 0x2000 * 4;
    cart._mbc = new MBC5();
    cart._mbc.reset();

    cart.writeROM(0x0000, 0x0A);
    cart.writeROM(0x4000, 0x09);
    cart.writeRAM(0xA000, 0x42);
    assert(cart._ram[0x2000] == 0x42);
    assert(cart.readRAM(0xA000) == 0x42);
}

// MBC2 RAM is 4 bits wide; the upper bits read as 1. Disabled RAM reads 0xFF.
unittest {
    import Core.MBC.MBC2;

    Cart cart = new Cart();
    cart._hardware = Hardware.RAM;
    cart._ramMask = 0x0F;
    cart._ram.length = 512;
    cart._mbc = new MBC2();
    cart._mbc.reset();

    cart.writeROM(0x0000, 0x0A);
    cart.writeRAM(0xA000, 0x35);
    assert(cart.readRAM(0xA000) == 0xF5);

    cart.writeROM(0x0000, 0x00);
    assert(cart.readRAM(0xA000) == 0xFF);
}

// MBC1 can map other banks at 0000-3FFF.
unittest {
    import Core.MBC.MBC1;

    Cart cart = new Cart();
    cart._rom.length = ROM_BANK_SIZE * 64;
    cart._rom[ROM_BANK_SIZE * 0x20] = 0x20;
    cart._mbc = new MBC1(Wiring.STANDARD);
    cart._mbc.reset();

    cart.writeROM(0x4000, 0x01);
    cart.writeROM(0x6000, 0x01);
    assert(cart.readROM(0x0000) == 0x20);
}

// MBC1 multicarts repeat the Nintendo logo in the header of the game at bank 0x10.
unittest {
    import Core.MBC.MBC1;

    Cart cart = new Cart();
    cart._rom.length = ROM_BANK_SIZE * 64;
    foreach (ubyte i; 0 .. 48) {
        cart._rom[0x0104 + i] = cast(ubyte)(i + 1);
    }
    assert(cart.mbc1Wiring() == Wiring.STANDARD);

    cart._rom[ROM_BANK_SIZE * 0x10 + 0x0104 .. ROM_BANK_SIZE * 0x10 + 0x0134] = cart._rom[0x0104 .. 0x0134];
    assert(cart.mbc1Wiring() == Wiring.MULTICART);

    cart._rom.length = ROM_BANK_SIZE * 128;
    assert(cart.mbc1Wiring() == Wiring.STANDARD);
}

// Without an MBC, RAM is always enabled.
unittest {
    Cart cart = new Cart();
    cart._hardware = Hardware.RAM;
    cart._ramMask = 0xFF;
    cart._ram.length = 0x2000;
    cart._mbc = new MBCNone();
    cart._mbc.reset();

    cart.writeRAM(0xA000, 0x42);
    assert(cart.readRAM(0xA000) == 0x42);
}
