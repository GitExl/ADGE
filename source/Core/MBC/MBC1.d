module Core.MBC.MBC1;

import std.stdio;

import Core.MBC.IMBC;


private enum SwitchMode : ubyte {
    ROM,
    RAM,
}

public final class MBC1 : IMBC {
    private ubyte _romBank;
    private SwitchMode _switchMode;

    private ubyte _ramBank;
    private bool _ramWriteEnabled;

    public void reset() {
        _romBank = 1;
        _switchMode = SwitchMode.ROM;

        _ramBank = 0;
        _ramWriteEnabled = false;
    }

    public void write(immutable ushort address, immutable ubyte value) {
        switch (address & 0xF000) {

            // RAM enable.
            case 0x0000:
            case 0x1000:
                _ramWriteEnabled = (value == 0x0A);
                break;

            // ROM bank select lower bits.
            case 0x2000:
            case 0x3000:
                setROMBank((_romBank & 0x60) | (value & 0x1F));
                break;

            // ROM bank select upper bits\RAM bank select.
            case 0x4000:
            case 0x5000:
                if (_switchMode == SwitchMode.RAM) {
                    _ramBank = value & 0x03;
                } else if (_switchMode == SwitchMode.ROM) {
                    setROMBank((_romBank & 0x1F) | (value & 0x03) << 5);
                }
                break;

            // ROM\RAM bank switch.
            case 0x6000:
            case 0x7000:
                if (value & 0x01) {
                    _switchMode = SwitchMode.RAM;
                    setROMBank(_romBank & 0x1F);
                } else {
                    _switchMode = SwitchMode.ROM;
                    _ramBank = 0;
                }
                break;

            default:
                throw new Exception("Unhandled MBC ROM write.");
        }
    }

    private void setROMBank(immutable ubyte bank) {
        _romBank = bank;
        if (_romBank == 0x00 || _romBank == 0x20 || _romBank == 0x40 || _romBank == 0x60) {
            _romBank++;
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
        return _ramWriteEnabled;
    }

    @property
    public string name() {
        return "MBC1";
    }
}