module Core.MBC.MBC2;

import Core.MBC.IMBC;


// Address bit 8 selects between the RAM enable and ROM bank registers in 0000-3FFF.
private immutable ushort REGISTER_SELECT = 0x0100;
private immutable ushort REGISTERS_END = 0x4000;
private immutable ubyte REGISTER_MASK = 0x0F;

public final class MBC2 : IMBC {
    private ubyte _romBank;
    private bool _ramEnabled;

    public void reset() {
        _romBank = 1;
        _ramEnabled = false;
    }

    public void write(immutable ushort address, immutable ubyte value) {
        if (address >= REGISTERS_END) {
            return;
        }

        if (!(address & REGISTER_SELECT)) {
            _ramEnabled = (value & REGISTER_MASK) == 0x0A;
            return;
        }

        _romBank = value & REGISTER_MASK;
        if (!_romBank) {
            _romBank = 1;
        }
    }

    @property
    public int lowRomBank() {
        return 0;
    }

    @property
    public int romBank() {
        return _romBank;
    }

    @property
    public int ramBank() {
        return 0;
    }

    @property
    public bool ramEnabled() {
        return _ramEnabled;
    }

    @property
    public string name() {
        return "MBC2";
    }
}

// Address bit 8 selects the register anywhere in 0000-3FFF.
unittest {
    MBC2 mbc = new MBC2();
    mbc.reset();

    mbc.write(0x3EFF, 0x0A);
    assert(mbc.ramEnabled);

    mbc.write(0x00FF, 0x00);
    assert(!mbc.ramEnabled);

    mbc.write(0x0100, 0x05);
    assert(mbc.romBank == 5);

    mbc.write(0x3FFF, 0x07);
    assert(mbc.romBank == 7);
}

// Registers are 4 bits wide. ROM bank 0 selects bank 1.
unittest {
    MBC2 mbc = new MBC2();
    mbc.reset();

    mbc.write(0x0000, 0xFA);
    assert(mbc.ramEnabled);

    mbc.write(0x0100, 0xF3);
    assert(mbc.romBank == 3);

    mbc.write(0x0100, 0x10);
    assert(mbc.romBank == 1);
}

// Writes to 4000-7FFF are ignored.
unittest {
    MBC2 mbc = new MBC2();
    mbc.reset();

    mbc.write(0x4100, 0x05);
    mbc.write(0x7FFF, 0x0A);
    assert(mbc.romBank == 1);
    assert(!mbc.ramEnabled);
}
