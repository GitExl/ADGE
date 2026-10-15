module Core.MBC.MBCNone;

import Core.MBC.IMBC;


public final class MBCNone : IMBC {
    public void reset() {
    }

    public void write(immutable ushort address, immutable ubyte value) {
    }

    @property
    public int lowRomBank() {
        return 0;
    }

    @property
    public int romBank() {
        return 1;
    }

    @property
    public int ramBank() {
        return 0;
    }

    @property
    public bool ramEnabled() {
        return true;
    }

    @property
    public string name() {
        return "None";
    }
}