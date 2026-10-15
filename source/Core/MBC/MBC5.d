module Core.MBC.MBC5;

import Core.MBC.IMBC;


public final class MBC5 : IMBC {
    private ushort _romBank;
    private ubyte _ramBank;
    private bool _ramEnabled;

    public void reset() {
        _romBank = 1;
        _ramBank = 0;
        _ramEnabled = false;
    }

    public void write(immutable ushort address, immutable ubyte value) {
        switch (address & 0xF000) {

            // RAM enable.
            case 0x0000:
            case 0x1000:
                _ramEnabled = (value == 0x0A);
                break;

            // ROM bank select lower 8 bits.
            case 0x2000:
                _romBank = (_romBank & 0x100) | value;
                break;

            // ROM bank select bit 8.
            case 0x3000:
                _romBank = (_romBank & 0xFF) | (value & 0x01) << 8;
                break;

            // RAM bank select. Bit 3 drives the rumble motor on rumble carts.
            case 0x4000:
            case 0x5000:
                _ramBank = value & 0x0F;
                break;

            default:
                break;
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
        return _ramBank;
    }

    @property
    public bool ramEnabled() {
        return _ramEnabled;
    }

    @property
    public string name() {
        return "MBC5";
    }
}

// ROM bank is 9 bits, split over two registers. Bank 0 is selectable.
unittest {
    MBC5 mbc = new MBC5();
    mbc.reset();

    mbc.write(0x2000, 0x00);
    assert(mbc.romBank == 0x000);

    mbc.write(0x2FFF, 0xA5);
    mbc.write(0x3000, 0x01);
    assert(mbc.romBank == 0x1A5);

    mbc.write(0x3FFF, 0xFE);
    assert(mbc.romBank == 0x0A5);
}

unittest {
    MBC5 mbc = new MBC5();
    mbc.reset();

    mbc.write(0x4000, 0x0F);
    assert(mbc.ramBank == 0x0F);

    mbc.write(0x5FFF, 0xF3);
    assert(mbc.ramBank == 0x03);
}

// Only exactly 0x0A enables RAM; all 8 bits are compared.
// See Gekkio's "Game Boy: Complete Technical Reference", MBC5 RAMG.
unittest {
    MBC5 mbc = new MBC5();
    mbc.reset();

    mbc.write(0x0000, 0x0A);
    assert(mbc.ramEnabled);

    mbc.write(0x1FFF, 0x1A);
    assert(!mbc.ramEnabled);
}

// The 0x6000-0x7FFF range has no register.
unittest {
    MBC5 mbc = new MBC5();
    mbc.reset();

    mbc.write(0x6000, 0xFF);
    mbc.write(0x7FFF, 0xFF);
    assert(mbc.romBank == 1);
    assert(mbc.ramBank == 0);
}
