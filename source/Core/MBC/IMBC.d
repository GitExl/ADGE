module Core.MBC.IMBC;


public interface IMBC {
    public void reset();
    public void write(immutable ushort address, immutable ubyte value);

    @property public int ramBank();

    // Banks mapped at 0000-3FFF and 4000-7FFF.
    @property public int lowRomBank();
    @property public int romBank();

    @property public bool ramEnabled();
    @property public string name();
}
