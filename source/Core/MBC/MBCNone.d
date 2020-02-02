module Core.MBC.MBCNone;

import Core.MBC.IMBC;


public final class MBCNone : IMBC {
	public void reset() {
	}

	public void write(immutable ushort address, immutable ubyte value) {
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
	public bool ramWriteEnabled() {
		return false;
	}

	@property
	public string name() {
		return "None";
	}
}