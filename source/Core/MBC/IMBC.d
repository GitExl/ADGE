module Core.MBC.IMBC;


public interface IMBC {
	public void reset();
	public void write(immutable ushort address, immutable ubyte value);

	@property public int ramBank();
	@property public int romBank();
	@property public bool ramWriteEnabled();
	@property public string name();
}
