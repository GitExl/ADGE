module Core.MBC.MBC2;

import Core.MBC.IMBC;


public final class MBC2 : IMBC {
	private ubyte _romBank;
    private bool _ramWriteEnabled;

	public void reset() {
		_romBank = 1;
        _ramWriteEnabled = false;
	}

	public void write(immutable ushort address, immutable ubyte value) {
		switch (address & 0xF000) {

            // RAM enable.
			// The least significant bit of the upper address byte must not be set.
            case 0x0000:
            case 0x1000:
                if (!((address >> 8) & 0x01)) {
					_ramWriteEnabled = (value == 0x0A);
				}
                break;

			// ROM bank select.
			// The least significant bit of the upper address byte must be set.
            case 0x2000:
            case 0x3000:
				if ((address >> 8) & 0x01) {	
					_romBank = value & 0x0F;	
				}
                break;

            default:
                throw new Exception("Unhandled MBC ROM write.");
        }
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
	public bool ramWriteEnabled() {
		return _ramWriteEnabled;
	}

	@property
	public string name() {
		return "MBC2";
	}
}