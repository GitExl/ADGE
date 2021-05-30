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

import Core.IGameboyDevice;
import Core.Gameboy;


private enum Hardware : ubyte {
    RAM     = 0x01,
    BATTERY = 0x02,
    TIMER   = 0x04,
    RUMBLE  = 0x08,
    CAMERA  = 0x10,
}

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
            case 0x00: _ram.length = 0x0000; break;
            case 0x01: _ram.length = 0x0800; break;
            case 0x02: _ram.length = 0x2000; break;
            case 0x03: _ram.length = 0x8000; break;
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
            case 0x52: _sizeROM = 0x4000 * 72; break;
            case 0x53: _sizeROM = 0x4000 * 80; break;
            case 0x54: _sizeROM = 0x4000 * 96; break;
            default:
                throw new Exception("Invalid cartridge ROM size.");
        }

        _ramMask = 0xFF;
        switch (_rom[0x0147]) {
            case 0x00: _mbc = new MBCNone(); _hardware = cast(Hardware)(0); break;
            case 0x01: _mbc = new MBC1(); _hardware = cast(Hardware)(0); break;
            case 0x02: _mbc = new MBC1(); _hardware = cast(Hardware)(Hardware.RAM); break;
            case 0x03: _mbc = new MBC1(); _hardware = cast(Hardware)(Hardware.RAM | Hardware.BATTERY); break;
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
            //case 0x19: _mbc = MBC.MBC5; _hardware = cast(Hardware)(0); break;
            //case 0x1A: _mbc = MBC.MBC5; _hardware = cast(Hardware)(Hardware.RAM); break;
            //case 0x1B: _mbc = MBC.MBC5; _hardware = cast(Hardware)(Hardware.RAM | Hardware.BATTERY); break;
            //case 0x1C: _mbc = MBC.MBC5; _hardware = cast(Hardware)(Hardware.RUMBLE); break;
            //case 0x1D: _mbc = MBC.MBC5; _hardware = cast(Hardware)(Hardware.RUMBLE | Hardware.RAM); break;
            //case 0x1E: _mbc = MBC.MBC5; _hardware = cast(Hardware)(Hardware.RUMBLE | Hardware.RAM | Hardware.BATTERY); break;
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
        if (address < 0x4000) {
            return _rom[address];
        }

        return _rom[_mbc.romBank * 0x4000 + (address - 0x4000)];
    }

    public void writeROM(immutable ushort address, immutable ubyte value) {
        _mbc.write(address, value);
    }

    public ubyte readRAM(immutable ushort address) {
        if (!(_hardware & Hardware.RAM)) {
            return 0;
        }
        
        return _ram[_mbc.ramBank * 0x2000 + (address - 0xA000)] & _ramMask;
    }

    public void writeRAM(immutable ushort address, immutable ubyte value) {
        if (!(_hardware & Hardware.RAM)) {
            return;
        }
        if (!_mbc.ramWriteEnabled) {
            return;
        }

        _ram[_mbc.ramBank * 0x2000 + (address - 0xA000)] = value & _ramMask;
    }

    public void storeRAM() {
        if (!(_hardware & Hardware.RAM) || !(_hardware & Hardware.BATTERY)) {
            return;
        }

        std.file.write(_ramFileName, _ram);
        writefln("Stored cartridge RAM.");
    }

    public void restoreRAM() {
        if (!(_hardware & Hardware.RAM) || !(_hardware & Hardware.BATTERY)) {
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