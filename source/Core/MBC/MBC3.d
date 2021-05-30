module Core.MBC.MBC3;

import Core.MBC.IMBC;


public final class MBC3 : IMBC {
    private ubyte _romBank;
    private ubyte _ramBank;
    private bool _ramAndRTCWriteEnabled;

    public void reset() {
        _romBank = 1;
        _ramBank = 0;
        _ramAndRTCWriteEnabled = false;
    }

    public void write(immutable ushort address, immutable ubyte value) {
        switch (address & 0xF000) {

            // RAM enable.
            case 0x0000:
            case 0x1000:
                _ramAndRTCWriteEnabled = (value == 0x0A);
                break;

            // ROM bank select lower bits.
            case 0x2000:
            case 0x3000:
                if (value == 0) {
                    _romBank = 1;
                } else {
                    _romBank = value & 0x7F;
                }
                break;

            // RAM bank\RTC select.
            case 0x4000:
            case 0x5000:
                if (value <= 0x03) {
                    _ramBank = value;
                } else {
                    // RTC map
                }
                break;

            // Latch clock data.
            case 0x6000:
            case 0x7000:
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
        return _ramBank;
    }

    @property
    public bool ramWriteEnabled() {
        return _ramAndRTCWriteEnabled;
    }

    @property
    public string name() {
        return "MBC3";
    }
}