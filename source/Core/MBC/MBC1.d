module Core.MBC.MBC1;

import std.stdio;

import Core.MBC.IMBC;


private enum SwitchMode : ubyte {
    ROM,
    RAM,
}

// Multicarts connect only 4 bits of BANK1, so BANK2 selects 256 KiB games.
public enum Wiring {
    STANDARD,
    MULTICART,
}

public final class MBC1 : IMBC {
    private ubyte _bank1;
    private ubyte _bank2;
    private SwitchMode _switchMode;
    private bool _ramEnabled;

    private ubyte _bank1Mask;
    private uint _bank2Shift;

    public this(immutable Wiring wiring) {
        _bank1Mask = wiring == Wiring.MULTICART ? 0x0F : 0x1F;
        _bank2Shift = wiring == Wiring.MULTICART ? 4 : 5;
    }

    public void reset() {
        _bank1 = 1;
        _bank2 = 0;
        _switchMode = SwitchMode.ROM;
        _ramEnabled = false;
    }

    public void write(immutable ushort address, immutable ubyte value) {
        switch (address & 0xF000) {

            // RAM enable.
            case 0x0000:
            case 0x1000:
                _ramEnabled = (value & 0x0F) == 0x0A;
                break;

            // ROM bank select lower bits. Bank 0 selects 1, checked on all 5 bits even on multicarts.
            case 0x2000:
            case 0x3000:
                _bank1 = value & 0x1F;
                if (!_bank1) {
                    _bank1 = 1;
                }
                break;

            // ROM bank select upper bits\RAM bank select.
            case 0x4000:
            case 0x5000:
                _bank2 = value & 0x03;
                break;

            // Mode 1 applies BANK2 to 0000-3FFF and to the RAM bank.
            case 0x6000:
            case 0x7000:
                _switchMode = (value & 0x01) ? SwitchMode.RAM : SwitchMode.ROM;
                break;

            default:
                throw new Exception("Unhandled MBC ROM write.");
        }
    }

    @property
    public int lowRomBank() {
        if (_switchMode == SwitchMode.ROM) {
            return 0;
        }

        return _bank2 << _bank2Shift;
    }

    @property
    public int romBank() {
        return (_bank2 << _bank2Shift) | (_bank1 & _bank1Mask);
    }

    @property
    public int ramBank() {
        if (_switchMode == SwitchMode.ROM) {
            return 0;
        }

        return _bank2;
    }

    @property
    public bool ramEnabled() {
        return _ramEnabled;
    }

    @property
    public string name() {
        return "MBC1";
    }
}

// RAMG compares only the low 4 bits.
unittest {
    MBC1 mbc = new MBC1(Wiring.STANDARD);
    mbc.reset();

    mbc.write(0x1FFF, 0x1A);
    assert(mbc.ramEnabled);

    mbc.write(0x0000, 0xA0);
    assert(!mbc.ramEnabled);
}

// BANK2 supplies bits 5-6 of the 4000-7FFF bank in both modes, and of the 0000-3FFF bank in mode 1.
unittest {
    MBC1 mbc = new MBC1(Wiring.STANDARD);
    mbc.reset();

    mbc.write(0x2000, 0x05);
    mbc.write(0x4000, 0x02);
    assert(mbc.romBank == 0x45);
    assert(mbc.lowRomBank == 0x00);

    mbc.write(0x6000, 0x01);
    assert(mbc.romBank == 0x45);
    assert(mbc.lowRomBank == 0x40);

    mbc.write(0x6000, 0x00);
    assert(mbc.lowRomBank == 0x00);
}

// Only the 5 bits of BANK1 are checked for 0.
unittest {
    MBC1 mbc = new MBC1(Wiring.STANDARD);
    mbc.reset();

    mbc.write(0x4000, 0x01);
    mbc.write(0x2000, 0xE0);
    assert(mbc.romBank == 0x21);
}

// BANK2 selects the RAM bank in mode 1 only, and survives mode changes.
unittest {
    MBC1 mbc = new MBC1(Wiring.STANDARD);
    mbc.reset();

    mbc.write(0x4000, 0x03);
    assert(mbc.ramBank == 0);

    mbc.write(0x6000, 0x01);
    assert(mbc.ramBank == 3);

    mbc.write(0x6000, 0x00);
    mbc.write(0x6000, 0x01);
    assert(mbc.ramBank == 3);
}

unittest {
    MBC1 mbc = new MBC1(Wiring.MULTICART);
    mbc.reset();

    mbc.write(0x2000, 0x15);
    mbc.write(0x4000, 0x02);
    assert(mbc.romBank == 0x25);

    mbc.write(0x6000, 0x01);
    assert(mbc.lowRomBank == 0x20);

    // BANK1 bit 4 still counts for the 0 check.
    mbc.write(0x2000, 0x10);
    assert(mbc.romBank == 0x20);
}
