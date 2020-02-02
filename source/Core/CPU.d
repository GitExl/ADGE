module Core.CPU;

import std.stdio;
import std.string;

import Core.MMU;
import Core.Debugger;
import Core.IGameboyDevice;
import Core.Gameboy;


// ALU flags set by many instructions.
public enum ALUFlag : ubyte {
    CARRY      = 0x10,
    CARRY_HALF = 0x20,
    SUBTRACT   = 0x40,
    ZERO       = 0x80,
}

// Interrupt enable\triggered flags.
public enum InterruptFlag : ubyte {
    NONE       = 0x00,
    VBLANK     = 0x01,
    LCD_STATUS = 0x02,
    TIMER      = 0x04,
    SERIAL     = 0x08,
    JOYPAD     = 0x10,
}

// CPU states.
public enum State : ubyte {
    NORMAL,
    HALTED,
    STOPPED,
}


// CPU registers.
public struct Registers {
    union {
        ushort AF;
        struct {
            ubyte F;
            ubyte A;
        }
    }

    union {
        ushort BC;
        struct {
            ubyte C;
            ubyte B;
        }
    }
    union {
        ushort DE;
        struct {
            ubyte E;
            ubyte D;
        }
    }
    union {
        ushort HL;
        struct {
            ubyte L;
            ubyte H;
        }
    }

    ushort SP;
    ushort PC;
}

public final class CPU : IGameboyDevice {
    private Gameboy _gameboy;
    private MMU _mmu;
    private Debugger _dbg;

    private Registers _registers;
    private bool _haltBug = false;
    private bool _exitStop = false;

    private ubyte _dmaAddress;
    private uint _dmaCycles;
    private ushort _dmaCurrentSrc;
    private ushort _dmaCurrentDest;

    private State _state;

    private bool _interruptsEnableDelay;
    private bool _interruptsMasterEnable;
    
    private InterruptFlag _interruptFlags;
    private InterruptFlag _interruptsEnabled;
    private InterruptFlag _interruptQueue;

    public void attach(Gameboy gameboy) {
        _gameboy = gameboy;
        _mmu = gameboy.mmu;
        _dbg = gameboy.dbg;
    }

    public void reset() {
        _registers = Registers.init;

        _haltBug = false;
        _exitStop = false;

        _dmaAddress = 0;
        _dmaCycles = 0;
        _dmaCurrentSrc = 0;
        _dmaCurrentDest = 0;

        _state = State.NORMAL;

        _interruptsEnableDelay = false;
        _interruptsMasterEnable = false;

        _interruptFlags = InterruptFlag.NONE;
        _interruptsEnabled = InterruptFlag.NONE;
    }

    public void cycle() {

        // STOP state, all execution is stopped.
        if (_state == State.STOPPED) {

            // When exiting STOP, execution resumes 131072 cycles after it was disabled.
            if (_exitStop) {
                foreach (int i; 0..32768) {
                    opIO();
                }
                _state = State.NORMAL;
            } else {
                opIO();
            }

        // HALT state, clock cycles continue but no opcodes are decoded.
        } else if (_state == State.HALTED) {

            // HALT is stopped by any interrupt. If the interrupt master flag is enabled,
            // interrupts are serviced normally. If it is not, execution is continued from
            // the next instruction without servicing interrupts this cycle.
            if (!_interruptsMasterEnable && (_interruptsEnabled & _interruptFlags)) {
                _state = State.NORMAL;
                if (_gameboy.mode == GameboyMode.COLOR) {
                    opIO();
                } else {
                    _haltBug = true;
                }
            } else {
                handleInterrupts();
                testInterrupts();
                opIO();
            }

        // Regular fetch & execute.
        } else {

            // Handle previously queued interrupts, then check for new ones.
            handleInterrupts();
            if (_interruptsMasterEnable) {
                testInterrupts();
            }

            _dbg.cycle();
            immutable ubyte opcode = opRead8(_registers.PC++);

            // HALT bug in GMB mode: PC is frozen for one increment after exiting HALT when
            // the interrupt master flag is disabled.
            if (_haltBug) {
                _registers.PC--;
                _haltBug = false;
            }

            execute(opcode);
        }
    }

    // Test all interrupts and execute them if necessary.
    // Interrupt test and actual handling are one cycle apart. See https://mgba.io/2018/03/09/holy-grail-bugs-revisited/
    private void testInterrupts() {
        if (_interruptsEnabled & _interruptFlags & InterruptFlag.VBLANK) {
            _interruptQueue = InterruptFlag.VBLANK;
        } else if (_interruptsEnabled & _interruptFlags & InterruptFlag.LCD_STATUS) {
            _interruptQueue = InterruptFlag.LCD_STATUS;
        } else if (_interruptsEnabled & _interruptFlags & InterruptFlag.TIMER) {
            _interruptQueue = InterruptFlag.TIMER;
        } else if (_interruptsEnabled & _interruptFlags & InterruptFlag.SERIAL) {
            _interruptQueue = InterruptFlag.SERIAL;
        } else if (_interruptsEnabled & _interruptFlags & InterruptFlag.JOYPAD) {
            _interruptQueue = InterruptFlag.JOYPAD;
        }
    }

    // Actually handle any queued interrupts.
    private void handleInterrupts() {
        if (_interruptQueue & InterruptFlag.VBLANK) {
            executeInterrupt(InterruptFlag.VBLANK, 0x40);
        } else if (_interruptQueue & InterruptFlag.LCD_STATUS) {
            executeInterrupt(InterruptFlag.LCD_STATUS, 0x48);
        } else if (_interruptQueue & InterruptFlag.TIMER) {
            executeInterrupt(InterruptFlag.TIMER, 0x50);
        } else if (_interruptQueue & InterruptFlag.SERIAL) {
            executeInterrupt(InterruptFlag.SERIAL, 0x58);
        } else if (_interruptQueue & InterruptFlag.JOYPAD) {
            executeInterrupt(InterruptFlag.JOYPAD, 0x60);
        }
    }

    // Executes an interrupt.
    private void executeInterrupt(immutable InterruptFlag flag, immutable ushort address) {

        // Interrupts exit HALT state (without the DMG HALT bug ocurring).
        if (_state == State.HALTED) {
            _state = State.NORMAL;
        }

        // Disable interrupts.
        _interruptFlags &= ~cast(int)flag;
        _interruptQueue &= ~cast(int)flag;
        _interruptsMasterEnable = false;

        opIO();
        opIO();

        // Push PC to stack, resume from interrupt address.
        opWrite8(--_registers.SP, cast(ubyte)(_registers.PC >> 8));
        opWrite8(--_registers.SP, cast(ubyte)(_registers.PC >> 0));

        _registers.PC = address;
        opIO();
    }

    // Sets an interrupt flag so that it will trigger if enabled.
    public void triggerInterrupt(immutable InterruptFlag flags) {
        _interruptFlags |= flags;
    }

    // Triggers an exit from a STOP instruction.
    public void exitStop() {
        _exitStop = true;
    }

    // Updates subsystems for a single CPU cycle.
    private void opIO() {
        if (_interruptsEnableDelay) {
            _interruptsEnableDelay = false;
            _interruptsMasterEnable = true;
        }

        // DMA memory transfer.
        // Transfer 4 bytes per cycle, for 160 cycles.
        if (_dmaCycles) {            
            if (_dmaCycles <= 160) {
                _mmu.write8(_dmaCurrentDest++, _mmu.read8(_dmaCurrentSrc++));
                _mmu.write8(_dmaCurrentDest++, _mmu.read8(_dmaCurrentSrc++));
                _mmu.write8(_dmaCurrentDest++, _mmu.read8(_dmaCurrentSrc++));
                _mmu.write8(_dmaCurrentDest++, _mmu.read8(_dmaCurrentSrc++));
            }

            _dmaCycles -= 4;
        }

        _gameboy.cycle();
    }

    // Single cycle instruction to read a byte from memory.
    private ubyte opRead8(immutable ushort address) {
        opIO();

        if (isAddressInDMAUse(address)) {
            return 0;
        }
        
        return _mmu.read8(address);
    }

    // Two cycle instruction to read a word from memory;
    private ushort opRead16(immutable ushort address) {
        opIO();
        ushort data = _mmu.read8(address);
        opIO();
        data |= _mmu.read8(cast(ushort)(address + 1)) << 8;
        return data;
    }

    // Single cycle instruction to write a byte to memory.
    private void opWrite8(immutable ushort address, immutable ubyte data) {
        opIO();

        if (isAddressInDMAUse(address)) {
            return;
        }

        _mmu.write8(address, data);
    }

    // Executes an opcode.
    private void execute(immutable ubyte opcode) {
        switch (opcode) {

            // NOP
            case 0x00: break;

            // LD (nn), SP
            case 0x08: opLDnnSP(); break;

            // LD n, d8
            case 0x06: _registers.B = opRead8(_registers.PC++); break;
            case 0x0E: _registers.C = opRead8(_registers.PC++); break;
            case 0x16: _registers.D = opRead8(_registers.PC++); break;
            case 0x1E: _registers.E = opRead8(_registers.PC++); break;
            case 0x26: _registers.H = opRead8(_registers.PC++); break;
            case 0x2E: _registers.L = opRead8(_registers.PC++); break;

            // LD nn, d16
            case 0x01: _registers.BC = opRead16(_registers.PC); _registers.PC += 2; break;
            case 0x11: _registers.DE = opRead16(_registers.PC); _registers.PC += 2; break;
            case 0x21: _registers.HL = opRead16(_registers.PC); _registers.PC += 2; break;
            case 0x31: _registers.SP = opRead16(_registers.PC); _registers.PC += 2; break;
            case 0xF9: _registers.SP = _registers.HL; opIO(); break;

            // LD A, n
            case 0x78: _registers.A = _registers.B; break;
            case 0x79: _registers.A = _registers.C; break;
            case 0x7A: _registers.A = _registers.D; break;
            case 0x7B: _registers.A = _registers.E; break;
            case 0x7C: _registers.A = _registers.H; break;
            case 0x7D: _registers.A = _registers.L; break;
            case 0x7E: _registers.A = opRead8(_registers.HL); break;
            case 0x7F: _registers.A = _registers.A; break;

            // LD B, n
            case 0x40: _registers.B = _registers.B; break;
            case 0x41: _registers.B = _registers.C; break;
            case 0x42: _registers.B = _registers.D; break;
            case 0x43: _registers.B = _registers.E; break;
            case 0x44: _registers.B = _registers.H; break;
            case 0x45: _registers.B = _registers.L; break;
            case 0x46: _registers.B = opRead8(_registers.HL); break;
            case 0x47: _registers.B = _registers.A; break;

            // LD C, n
            case 0x48: _registers.C = _registers.B; break;
            case 0x49: _registers.C = _registers.C; break;
            case 0x4A: _registers.C = _registers.D; break;
            case 0x4B: _registers.C = _registers.E; break;
            case 0x4C: _registers.C = _registers.H; break;
            case 0x4D: _registers.C = _registers.L; break;
            case 0x4E: _registers.C = opRead8(_registers.HL); break;
            case 0x4F: _registers.C = _registers.A; break;

            // LD D, n
            case 0x50: _registers.D = _registers.B; break;
            case 0x51: _registers.D = _registers.C; break;
            case 0x52: _registers.D = _registers.D; break;
            case 0x53: _registers.D = _registers.E; break;
            case 0x54: _registers.D = _registers.H; break;
            case 0x55: _registers.D = _registers.L; break;
            case 0x56: _registers.D = opRead8(_registers.HL); break;
            case 0x57: _registers.D = _registers.A; break;

            // LD E, n
            case 0x58: _registers.E = _registers.B; break;
            case 0x59: _registers.E = _registers.C; break;
            case 0x5A: _registers.E = _registers.D; break;
            case 0x5B: _registers.E = _registers.E; break;
            case 0x5C: _registers.E = _registers.H; break;
            case 0x5D: _registers.E = _registers.L; break;
            case 0x5E: _registers.E = opRead8(_registers.HL); break;
            case 0x5F: _registers.E = _registers.A; break;

            // LD H, n
            case 0x60: _registers.H = _registers.B; break;
            case 0x61: _registers.H = _registers.C; break;
            case 0x62: _registers.H = _registers.D; break;
            case 0x63: _registers.H = _registers.E; break;
            case 0x64: _registers.H = _registers.H; break;
            case 0x65: _registers.H = _registers.L; break;
            case 0x66: _registers.H = opRead8(_registers.HL); break;
            case 0x67: _registers.H = _registers.A; break;

            // LD L, n
            case 0x68: _registers.L = _registers.B; break;
            case 0x69: _registers.L = _registers.C; break;
            case 0x6A: _registers.L = _registers.D; break;
            case 0x6B: _registers.L = _registers.E; break;
            case 0x6C: _registers.L = _registers.H; break;
            case 0x6D: _registers.L = _registers.L; break;
            case 0x6E: _registers.L = opRead8(_registers.HL); break;
            case 0x6F: _registers.L = _registers.A; break;

            // LD (HL), n
            case 0x70: opWrite8(_registers.HL, _registers.B); break;
            case 0x71: opWrite8(_registers.HL, _registers.C); break;
            case 0x72: opWrite8(_registers.HL, _registers.D); break;
            case 0x73: opWrite8(_registers.HL, _registers.E); break;
            case 0x74: opWrite8(_registers.HL, _registers.H); break;
            case 0x75: opWrite8(_registers.HL, _registers.L); break;
            case 0x36: opWrite8(_registers.HL, opRead8(_registers.PC++)); break;
            case 0x77: opWrite8(_registers.HL, _registers.A); break;

            // LD (nn), A
            case 0x02: opWrite8(_registers.BC, _registers.A); break;
            case 0x12: opWrite8(_registers.DE, _registers.A); break;
            case 0xEA: opWrite8(opRead16(_registers.PC), _registers.A); _registers.PC += 2; break;

            // LD A, (nn)
            case 0x0A: _registers.A = opRead8(_registers.BC); break;
            case 0x1A: _registers.A = opRead8(_registers.DE); break;
            case 0xFA: _registers.A = opRead8(opRead16(_registers.PC)); _registers.PC += 2; break;
            case 0x3E: _registers.A = opRead8(_registers.PC++); break;

            // LD A, (FF00 + n)
            case 0xF0: _registers.A = opRead8(0xFF00 + opRead8(_registers.PC++)); break;
            case 0xF2: _registers.A = opRead8(0xFF00 + _registers.C); break;

            // LD (FF00 + n), A
            case 0xE0: opWrite8(0xFF00 + opRead8(_registers.PC++), _registers.A); break;
            case 0xE2: opWrite8(0xFF00 + _registers.C, _registers.A); break;

            // LDD\I A, (HL)
            case 0x3A: _registers.A = opRead8(_registers.HL); _registers.HL--; break;
            case 0x2A: _registers.A = opRead8(_registers.HL); _registers.HL++; break;

            // LDD\I (HL), A
            case 0x32: opWrite8(_registers.HL, _registers.A), _registers.HL--; break;
            case 0x22: opWrite8(_registers.HL, _registers.A), _registers.HL++; break;

            // INC nn
            case 0x03: opIO(); _registers.BC++; break;
            case 0x13: opIO(); _registers.DE++; break;
            case 0x23: opIO(); _registers.HL++; break;
            case 0x33: opIO(); _registers.SP++; break;

            // DEC nn
            case 0x0B: opIO(); _registers.BC--; break;
            case 0x1B: opIO(); _registers.DE--; break;
            case 0x2B: opIO(); _registers.HL--; break;
            case 0x3B: opIO(); _registers.SP--; break;

            // INC n
            case 0x3C: _registers.A = opINC(_registers.A); break;
            case 0x04: _registers.B = opINC(_registers.B); break;
            case 0x0C: _registers.C = opINC(_registers.C); break;
            case 0x14: _registers.D = opINC(_registers.D); break;
            case 0x1C: _registers.E = opINC(_registers.E); break;
            case 0x24: _registers.H = opINC(_registers.H); break;
            case 0x2C: _registers.L = opINC(_registers.L); break;
            case 0x34: opWrite8(_registers.HL, opINC(opRead8(_registers.HL))); break;

            // DEC n
            case 0x3D: _registers.A = opDEC(_registers.A); break;
            case 0x05: _registers.B = opDEC(_registers.B); break;
            case 0x0D: _registers.C = opDEC(_registers.C); break;
            case 0x15: _registers.D = opDEC(_registers.D); break;
            case 0x1D: _registers.E = opDEC(_registers.E); break;
            case 0x25: _registers.H = opDEC(_registers.H); break;
            case 0x2D: _registers.L = opDEC(_registers.L); break;
            case 0x35: opWrite8(_registers.HL, opDEC(opRead8(_registers.HL))); break;

            // RL, RR
            case 0x07: _registers.A = opRLC(_registers.A, false); break;
            case 0x17: _registers.A = opRL(_registers.A, false); break;
            case 0x0F: _registers.A = opRRC(_registers.A, false); break;
            case 0x1F: _registers.A = opRR(_registers.A, false); break;

            // ADD HL, n
            case 0x09: _registers.HL = opADDHL(_registers.HL, _registers.BC); break;
            case 0x19: _registers.HL = opADDHL(_registers.HL, _registers.DE); break;
            case 0x29: _registers.HL = opADDHL(_registers.HL, _registers.HL); break;
            case 0x39: _registers.HL = opADDHL(_registers.HL, _registers.SP); break;

            // ADD SP, n
            case 0xE8: opSPADD(); break;

            // LDHL SP + n
            case 0xF8: opHLSP(); break;

            // ADD A, n
            case 0x87: _registers.A = opADD(_registers.A, _registers.A); break;
            case 0x80: _registers.A = opADD(_registers.A, _registers.B); break;
            case 0x81: _registers.A = opADD(_registers.A, _registers.C); break;
            case 0x82: _registers.A = opADD(_registers.A, _registers.D); break;
            case 0x83: _registers.A = opADD(_registers.A, _registers.E); break;
            case 0x84: _registers.A = opADD(_registers.A, _registers.H); break;
            case 0x85: _registers.A = opADD(_registers.A, _registers.L); break;
            case 0x86: _registers.A = opADD(_registers.A, opRead8(_registers.HL)); break;
            case 0xC6: _registers.A = opADD(_registers.A, opRead8(_registers.PC++)); break;

            // ADC A, n
            case 0x8F: _registers.A = opADC(_registers.A, _registers.A); break;
            case 0x88: _registers.A = opADC(_registers.A, _registers.B); break;
            case 0x89: _registers.A = opADC(_registers.A, _registers.C); break;
            case 0x8A: _registers.A = opADC(_registers.A, _registers.D); break;
            case 0x8B: _registers.A = opADC(_registers.A, _registers.E); break;
            case 0x8C: _registers.A = opADC(_registers.A, _registers.H); break;
            case 0x8D: _registers.A = opADC(_registers.A, _registers.L); break;
            case 0x8E: _registers.A = opADC(_registers.A, opRead8(_registers.HL)); break;
            case 0xCE: _registers.A = opADC(_registers.A, opRead8(_registers.PC++)); break;

            // SUB A, n
            case 0x97: _registers.A = opSUB(_registers.A, _registers.A); break;
            case 0x90: _registers.A = opSUB(_registers.A, _registers.B); break;
            case 0x91: _registers.A = opSUB(_registers.A, _registers.C); break;
            case 0x92: _registers.A = opSUB(_registers.A, _registers.D); break;
            case 0x93: _registers.A = opSUB(_registers.A, _registers.E); break;
            case 0x94: _registers.A = opSUB(_registers.A, _registers.H); break;
            case 0x95: _registers.A = opSUB(_registers.A, _registers.L); break;
            case 0x96: _registers.A = opSUB(_registers.A, opRead8(_registers.HL)); break;
            case 0xD6: _registers.A = opSUB(_registers.A, opRead8(_registers.PC++)); break;

            // SBC A, n
            case 0x9F: _registers.A = opSBC(_registers.A, _registers.A); break;
            case 0x98: _registers.A = opSBC(_registers.A, _registers.B); break;
            case 0x99: _registers.A = opSBC(_registers.A, _registers.C); break;
            case 0x9A: _registers.A = opSBC(_registers.A, _registers.D); break;
            case 0x9B: _registers.A = opSBC(_registers.A, _registers.E); break;
            case 0x9C: _registers.A = opSBC(_registers.A, _registers.H); break;
            case 0x9D: _registers.A = opSBC(_registers.A, _registers.L); break;
            case 0x9E: _registers.A = opSBC(_registers.A, opRead8(_registers.HL)); break;
            case 0xDE: _registers.A = opSBC(_registers.A, opRead8(_registers.PC++)); break;

            // AND n
            case 0xA7: _registers.A = opAND(_registers.A, _registers.A); break;
            case 0xA0: _registers.A = opAND(_registers.A, _registers.B); break;
            case 0xA1: _registers.A = opAND(_registers.A, _registers.C); break;
            case 0xA2: _registers.A = opAND(_registers.A, _registers.D); break;
            case 0xA3: _registers.A = opAND(_registers.A, _registers.E); break;
            case 0xA4: _registers.A = opAND(_registers.A, _registers.H); break;
            case 0xA5: _registers.A = opAND(_registers.A, _registers.L); break;
            case 0xA6: _registers.A = opAND(_registers.A, opRead8(_registers.HL)); break;
            case 0xE6: _registers.A = opAND(_registers.A, opRead8(_registers.PC++)); break;

            // OR n
            case 0xB7: _registers.A = opOR(_registers.A, _registers.A); break;
            case 0xB0: _registers.A = opOR(_registers.A, _registers.B); break;
            case 0xB1: _registers.A = opOR(_registers.A, _registers.C); break;
            case 0xB2: _registers.A = opOR(_registers.A, _registers.D); break;
            case 0xB3: _registers.A = opOR(_registers.A, _registers.E); break;
            case 0xB4: _registers.A = opOR(_registers.A, _registers.H); break;
            case 0xB5: _registers.A = opOR(_registers.A, _registers.L); break;
            case 0xB6: _registers.A = opOR(_registers.A, opRead8(_registers.HL)); break;
            case 0xF6: _registers.A = opOR(_registers.A, opRead8(_registers.PC++)); break;

            // XOR n
            case 0xAF: _registers.A = opXOR(_registers.A, _registers.A); break;
            case 0xA8: _registers.A = opXOR(_registers.A, _registers.B); break;
            case 0xA9: _registers.A = opXOR(_registers.A, _registers.C); break;
            case 0xAA: _registers.A = opXOR(_registers.A, _registers.D); break;
            case 0xAB: _registers.A = opXOR(_registers.A, _registers.E); break;
            case 0xAC: _registers.A = opXOR(_registers.A, _registers.H); break;
            case 0xAD: _registers.A = opXOR(_registers.A, _registers.L); break;
            case 0xAE: _registers.A = opXOR(_registers.A, opRead8(_registers.HL)); break;
            case 0xEE: _registers.A = opXOR(_registers.A, opRead8(_registers.PC++)); break;

            // CP n
            case 0xBF: opCP(_registers.A, _registers.A); break;
            case 0xB8: opCP(_registers.A, _registers.B); break;
            case 0xB9: opCP(_registers.A, _registers.C); break;
            case 0xBA: opCP(_registers.A, _registers.D); break;
            case 0xBB: opCP(_registers.A, _registers.E); break;
            case 0xBC: opCP(_registers.A, _registers.H); break;
            case 0xBD: opCP(_registers.A, _registers.L); break;
            case 0xBE: opCP(_registers.A, opRead8(_registers.HL)); break;
            case 0xFE: opCP(_registers.A, opRead8(_registers.PC++)); break;

            // PUSH nn
            case 0xF5: opPUSH(_registers.AF); break;
            case 0xC5: opPUSH(_registers.BC); break;
            case 0xD5: opPUSH(_registers.DE); break;
            case 0xE5: opPUSH(_registers.HL); break;

            // POP nn
            case 0xF1: _registers.AF = opPOP(); _registers.F &= 0xF0; break;
            case 0xC1: _registers.BC = opPOP(); break;
            case 0xD1: _registers.DE = opPOP(); break;
            case 0xE1: _registers.HL = opPOP(); break;

            // JP nn
            case 0xC3: opJP(); break;
            case 0xC2: opJPcc(ALUFlag.ZERO, false); break;
            case 0xCA: opJPcc(ALUFlag.ZERO, true); break;
            case 0xD2: opJPcc(ALUFlag.CARRY, false); break;
            case 0xDA: opJPcc(ALUFlag.CARRY, true); break;
            case 0xE9: _registers.PC = _registers.HL; break;

            // JR n
            case 0x18: opJR(); break;
            case 0x20: opJRcc(ALUFlag.ZERO, false); break;
            case 0x28: opJRcc(ALUFlag.ZERO, true); break;
            case 0x30: opJRcc(ALUFlag.CARRY, false); break;
            case 0x38: opJRcc(ALUFlag.CARRY, true); break;

            // CALL nn
            case 0xCD: opCALL(); break;
            case 0xC4: opCALLcc(ALUFlag.ZERO, false); break;
            case 0xCC: opCALLcc(ALUFlag.ZERO, true); break;
            case 0xD4: opCALLcc(ALUFlag.CARRY, false); break;
            case 0xDC: opCALLcc(ALUFlag.CARRY, true); break;

            // RET
            case 0xC9: opRET(); break;
            case 0xC0: opRETcc(ALUFlag.ZERO, false); break;
            case 0xC8: opRETcc(ALUFlag.ZERO, true); break;
            case 0xD0: opRETcc(ALUFlag.CARRY, false); break;
            case 0xD8: opRETcc(ALUFlag.CARRY, true); break;

            // RST
            case 0xC7: opRST(0x00); break;
            case 0xCF: opRST(0x08); break;
            case 0xD7: opRST(0x10); break;
            case 0xDF: opRST(0x18); break;
            case 0xE7: opRST(0x20); break;
            case 0xEF: opRST(0x28); break;
            case 0xF7: opRST(0x30); break;
            case 0xFF: opRST(0x38); break;

            // DAA
            case 0x27: _registers.A = opDAA(_registers.A); break;

            // CPLA
            case 0x2F: _registers.A = opCPL(_registers.A); break;

            // Carry flags.
            case 0x3F: opCCF(); break;
            case 0x37: opSCF(); break;

            // HALT, STOP
            case 0x76: _state = State.HALTED; break;
            case 0x10: _state = State.STOPPED; break;

            // DI, EI, RETI
            case 0xF3: _interruptsMasterEnable = false; break;
            case 0xFB: _interruptsEnableDelay = true; break;
            case 0xD9: opRETI(); break;

            // Extension opcode.
            case 0xCB: executeExtended(opRead8(_registers.PC++)); break;

            default:
                throw new Exception(format("CPU: invalid opcode 0x%02X.", opcode));
        }
    }

    // Executes an extended opcode.
    private void executeExtended(immutable ubyte opcode) {
        switch (opcode) {

            // RLC n
            case 0x07: _registers.A = opRLC(_registers.A, true); break;
            case 0x00: _registers.B = opRLC(_registers.B, true); break;
            case 0x01: _registers.C = opRLC(_registers.C, true); break;
            case 0x02: _registers.D = opRLC(_registers.D, true); break;
            case 0x03: _registers.E = opRLC(_registers.E, true); break;
            case 0x04: _registers.H = opRLC(_registers.H, true); break;
            case 0x05: _registers.L = opRLC(_registers.L, true); break;
            case 0x06: opWrite8(_registers.HL, opRLC(opRead8(_registers.HL), true)); break;

            // RL n
            case 0x17: _registers.A = opRL(_registers.A, true); break;
            case 0x10: _registers.B = opRL(_registers.B, true); break;
            case 0x11: _registers.C = opRL(_registers.C, true); break;
            case 0x12: _registers.D = opRL(_registers.D, true); break;
            case 0x13: _registers.E = opRL(_registers.E, true); break;
            case 0x14: _registers.H = opRL(_registers.H, true); break;
            case 0x15: _registers.L = opRL(_registers.L, true); break;
            case 0x16: opWrite8(_registers.HL, opRL(opRead8(_registers.HL), true)); break;

            // RRC n
            case 0x0F: _registers.A = opRRC(_registers.A, true); break;
            case 0x08: _registers.B = opRRC(_registers.B, true); break;
            case 0x09: _registers.C = opRRC(_registers.C, true); break;
            case 0x0A: _registers.D = opRRC(_registers.D, true); break;
            case 0x0B: _registers.E = opRRC(_registers.E, true); break;
            case 0x0C: _registers.H = opRRC(_registers.H, true); break;
            case 0x0D: _registers.L = opRRC(_registers.L, true); break;
            case 0x0E: opWrite8(_registers.HL, opRRC(opRead8(_registers.HL), true)); break;

            // RL n
            case 0x1F: _registers.A = opRR(_registers.A, true); break;
            case 0x18: _registers.B = opRR(_registers.B, true); break;
            case 0x19: _registers.C = opRR(_registers.C, true); break;
            case 0x1A: _registers.D = opRR(_registers.D, true); break;
            case 0x1B: _registers.E = opRR(_registers.E, true); break;
            case 0x1C: _registers.H = opRR(_registers.H, true); break;
            case 0x1D: _registers.L = opRR(_registers.L, true); break;
            case 0x1E: opWrite8(_registers.HL, opRR(opRead8(_registers.HL), true)); break;

            // SLA n
            case 0x27: _registers.A = opSLA(_registers.A); break;
            case 0x20: _registers.B = opSLA(_registers.B); break;
            case 0x21: _registers.C = opSLA(_registers.C); break;
            case 0x22: _registers.D = opSLA(_registers.D); break;
            case 0x23: _registers.E = opSLA(_registers.E); break;
            case 0x24: _registers.H = opSLA(_registers.H); break;
            case 0x25: _registers.L = opSLA(_registers.L); break;
            case 0x26: opWrite8(_registers.HL, opSLA(opRead8(_registers.HL))); break;

            // SRA n
            case 0x2F: _registers.A = opSRA(_registers.A); break;
            case 0x28: _registers.B = opSRA(_registers.B); break;
            case 0x29: _registers.C = opSRA(_registers.C); break;
            case 0x2A: _registers.D = opSRA(_registers.D); break;
            case 0x2B: _registers.E = opSRA(_registers.E); break;
            case 0x2C: _registers.H = opSRA(_registers.H); break;
            case 0x2D: _registers.L = opSRA(_registers.L); break;
            case 0x2E: opWrite8(_registers.HL, opSRA(opRead8(_registers.HL))); break;

            // SRL n
            case 0x3F: _registers.A = opSRL(_registers.A); break;
            case 0x38: _registers.B = opSRL(_registers.B); break;
            case 0x39: _registers.C = opSRL(_registers.C); break;
            case 0x3A: _registers.D = opSRL(_registers.D); break;
            case 0x3B: _registers.E = opSRL(_registers.E); break;
            case 0x3C: _registers.H = opSRL(_registers.H); break;
            case 0x3D: _registers.L = opSRL(_registers.L); break;
            case 0x3E: opWrite8(_registers.HL, opSRL(opRead8(_registers.HL))); break;

            // SWAP
            case 0x37: _registers.A = opSWAP(_registers.A); break;
            case 0x30: _registers.B = opSWAP(_registers.B); break;
            case 0x31: _registers.C = opSWAP(_registers.C); break;
            case 0x32: _registers.D = opSWAP(_registers.D); break;
            case 0x33: _registers.E = opSWAP(_registers.E); break;
            case 0x34: _registers.H = opSWAP(_registers.H); break;
            case 0x35: _registers.L = opSWAP(_registers.L); break;
            case 0x36: opWrite8(_registers.HL, opSWAP(opRead8(_registers.HL))); break;

            // BIT b, r
            case 0x40: opBIT(0x01, _registers.B); break;
            case 0x41: opBIT(0x01, _registers.C); break;
            case 0x42: opBIT(0x01, _registers.D); break;
            case 0x43: opBIT(0x01, _registers.E); break;
            case 0x44: opBIT(0x01, _registers.H); break;
            case 0x45: opBIT(0x01, _registers.L); break;
            case 0x46: opBIT(0x01, opRead8(_registers.HL)); break;
            case 0x47: opBIT(0x01, _registers.A); break;

            case 0x48: opBIT(0x02, _registers.B); break;
            case 0x49: opBIT(0x02, _registers.C); break;
            case 0x4A: opBIT(0x02, _registers.D); break;
            case 0x4B: opBIT(0x02, _registers.E); break;
            case 0x4C: opBIT(0x02, _registers.H); break;
            case 0x4D: opBIT(0x02, _registers.L); break;
            case 0x4E: opBIT(0x02, opRead8(_registers.HL)); break;
            case 0x4F: opBIT(0x02, _registers.A); break;

            case 0x50: opBIT(0x04, _registers.B); break;
            case 0x51: opBIT(0x04, _registers.C); break;
            case 0x52: opBIT(0x04, _registers.D); break;
            case 0x53: opBIT(0x04, _registers.E); break;
            case 0x54: opBIT(0x04, _registers.H); break;
            case 0x55: opBIT(0x04, _registers.L); break;
            case 0x56: opBIT(0x04, opRead8(_registers.HL)); break;
            case 0x57: opBIT(0x04, _registers.A); break;

            case 0x58: opBIT(0x08, _registers.B); break;
            case 0x59: opBIT(0x08, _registers.C); break;
            case 0x5A: opBIT(0x08, _registers.D); break;
            case 0x5B: opBIT(0x08, _registers.E); break;
            case 0x5C: opBIT(0x08, _registers.H); break;
            case 0x5D: opBIT(0x08, _registers.L); break;
            case 0x5E: opBIT(0x08, opRead8(_registers.HL)); break;
            case 0x5F: opBIT(0x08, _registers.A); break;

            case 0x60: opBIT(0x10, _registers.B); break;
            case 0x61: opBIT(0x10, _registers.C); break;
            case 0x62: opBIT(0x10, _registers.D); break;
            case 0x63: opBIT(0x10, _registers.E); break;
            case 0x64: opBIT(0x10, _registers.H); break;
            case 0x65: opBIT(0x10, _registers.L); break;
            case 0x66: opBIT(0x10, opRead8(_registers.HL)); break;
            case 0x67: opBIT(0x10, _registers.A); break;

            case 0x68: opBIT(0x20, _registers.B); break;
            case 0x69: opBIT(0x20, _registers.C); break;
            case 0x6A: opBIT(0x20, _registers.D); break;
            case 0x6B: opBIT(0x20, _registers.E); break;
            case 0x6C: opBIT(0x20, _registers.H); break;
            case 0x6D: opBIT(0x20, _registers.L); break;
            case 0x6E: opBIT(0x20, opRead8(_registers.HL)); break;
            case 0x6F: opBIT(0x20, _registers.A); break;

            case 0x70: opBIT(0x40, _registers.B); break;
            case 0x71: opBIT(0x40, _registers.C); break;
            case 0x72: opBIT(0x40, _registers.D); break;
            case 0x73: opBIT(0x40, _registers.E); break;
            case 0x74: opBIT(0x40, _registers.H); break;
            case 0x75: opBIT(0x40, _registers.L); break;
            case 0x76: opBIT(0x40, opRead8(_registers.HL)); break;
            case 0x77: opBIT(0x40, _registers.A); break;

            case 0x78: opBIT(0x80, _registers.B); break;
            case 0x79: opBIT(0x80, _registers.C); break;
            case 0x7A: opBIT(0x80, _registers.D); break;
            case 0x7B: opBIT(0x80, _registers.E); break;
            case 0x7C: opBIT(0x80, _registers.H); break;
            case 0x7D: opBIT(0x80, _registers.L); break;
            case 0x7E: opBIT(0x80, opRead8(_registers.HL)); break;
            case 0x7F: opBIT(0x80, _registers.A); break;

            // RES b, r
            case 0x80: _registers.B = opRES(0x01, _registers.B); break;
            case 0x81: _registers.C = opRES(0x01, _registers.C); break;
            case 0x82: _registers.D = opRES(0x01, _registers.D); break;
            case 0x83: _registers.E = opRES(0x01, _registers.E); break;
            case 0x84: _registers.H = opRES(0x01, _registers.H); break;
            case 0x85: _registers.L = opRES(0x01, _registers.L); break;
            case 0x86: opWrite8(_registers.HL, opRES(0x01, opRead8(_registers.HL))); break;
            case 0x87: _registers.A = opRES(0x01, _registers.A); break;

            case 0x88: _registers.B = opRES(0x02, _registers.B); break;
            case 0x89: _registers.C = opRES(0x02, _registers.C); break;
            case 0x8A: _registers.D = opRES(0x02, _registers.D); break;
            case 0x8B: _registers.E = opRES(0x02, _registers.E); break;
            case 0x8C: _registers.H = opRES(0x02, _registers.H); break;
            case 0x8D: _registers.L = opRES(0x02, _registers.L); break;
            case 0x8E: opWrite8(_registers.HL, opRES(0x02, opRead8(_registers.HL))); break;
            case 0x8F: _registers.A = opRES(0x02, _registers.A); break;

            case 0x90: _registers.B = opRES(0x04, _registers.B); break;
            case 0x91: _registers.C = opRES(0x04, _registers.C); break;
            case 0x92: _registers.D = opRES(0x04, _registers.D); break;
            case 0x93: _registers.E = opRES(0x04, _registers.E); break;
            case 0x94: _registers.H = opRES(0x04, _registers.H); break;
            case 0x95: _registers.L = opRES(0x04, _registers.L); break;
            case 0x96: opWrite8(_registers.HL, opRES(0x04, opRead8(_registers.HL))); break;
            case 0x97: _registers.A = opRES(0x04, _registers.A); break;

            case 0x98: _registers.B = opRES(0x08, _registers.B); break;
            case 0x99: _registers.C = opRES(0x08, _registers.C); break;
            case 0x9A: _registers.D = opRES(0x08, _registers.D); break;
            case 0x9B: _registers.E = opRES(0x08, _registers.E); break;
            case 0x9C: _registers.H = opRES(0x08, _registers.H); break;
            case 0x9D: _registers.L = opRES(0x08, _registers.L); break;
            case 0x9E: opWrite8(_registers.HL, opRES(0x08, opRead8(_registers.HL))); break;
            case 0x9F: _registers.A = opRES(0x08, _registers.A); break;

            case 0xA0: _registers.B = opRES(0x10, _registers.B); break;
            case 0xA1: _registers.C = opRES(0x10, _registers.C); break;
            case 0xA2: _registers.D = opRES(0x10, _registers.D); break;
            case 0xA3: _registers.E = opRES(0x10, _registers.E); break;
            case 0xA4: _registers.H = opRES(0x10, _registers.H); break;
            case 0xA5: _registers.L = opRES(0x10, _registers.L); break;
            case 0xA6: opWrite8(_registers.HL, opRES(0x10, opRead8(_registers.HL))); break;
            case 0xA7: _registers.A = opRES(0x10, _registers.A); break;

            case 0xA8: _registers.B = opRES(0x20, _registers.B); break;
            case 0xA9: _registers.C = opRES(0x20, _registers.C); break;
            case 0xAA: _registers.D = opRES(0x20, _registers.D); break;
            case 0xAB: _registers.E = opRES(0x20, _registers.E); break;
            case 0xAC: _registers.H = opRES(0x20, _registers.H); break;
            case 0xAD: _registers.L = opRES(0x20, _registers.L); break;
            case 0xAE: opWrite8(_registers.HL, opRES(0x20, opRead8(_registers.HL))); break;
            case 0xAF: _registers.A = opRES(0x20, _registers.A); break;

            case 0xB0: _registers.B = opRES(0x40, _registers.B); break;
            case 0xB1: _registers.C = opRES(0x40, _registers.C); break;
            case 0xB2: _registers.D = opRES(0x40, _registers.D); break;
            case 0xB3: _registers.E = opRES(0x40, _registers.E); break;
            case 0xB4: _registers.H = opRES(0x40, _registers.H); break;
            case 0xB5: _registers.L = opRES(0x40, _registers.L); break;
            case 0xB6: opWrite8(_registers.HL, opRES(0x40, opRead8(_registers.HL))); break;
            case 0xB7: _registers.A = opRES(0x40, _registers.A); break;

            case 0xB8: _registers.B = opRES(0x80, _registers.B); break;
            case 0xB9: _registers.C = opRES(0x80, _registers.C); break;
            case 0xBA: _registers.D = opRES(0x80, _registers.D); break;
            case 0xBB: _registers.E = opRES(0x80, _registers.E); break;
            case 0xBC: _registers.H = opRES(0x80, _registers.H); break;
            case 0xBD: _registers.L = opRES(0x80, _registers.L); break;
            case 0xBE: opWrite8(_registers.HL, opRES(0x80, opRead8(_registers.HL))); break;
            case 0xBF: _registers.A = opRES(0x80, _registers.A); break;

            // SET b, r
            case 0xC0: _registers.B = opSET(0x01, _registers.B); break;
            case 0xC1: _registers.C = opSET(0x01, _registers.C); break;
            case 0xC2: _registers.D = opSET(0x01, _registers.D); break;
            case 0xC3: _registers.E = opSET(0x01, _registers.E); break;
            case 0xC4: _registers.H = opSET(0x01, _registers.H); break;
            case 0xC5: _registers.L = opSET(0x01, _registers.L); break;
            case 0xC6: opWrite8(_registers.HL, opSET(0x01, opRead8(_registers.HL))); break;
            case 0xC7: _registers.A = opSET(0x01, _registers.A); break;

            case 0xC8: _registers.B = opSET(0x02, _registers.B); break;
            case 0xC9: _registers.C = opSET(0x02, _registers.C); break;
            case 0xCA: _registers.D = opSET(0x02, _registers.D); break;
            case 0xCB: _registers.E = opSET(0x02, _registers.E); break;
            case 0xCC: _registers.H = opSET(0x02, _registers.H); break;
            case 0xCD: _registers.L = opSET(0x02, _registers.L); break;
            case 0xCE: opWrite8(_registers.HL, opSET(0x02, opRead8(_registers.HL))); break;
            case 0xCF: _registers.A = opSET(0x02, _registers.A); break;

            case 0xD0: _registers.B = opSET(0x04, _registers.B); break;
            case 0xD1: _registers.C = opSET(0x04, _registers.C); break;
            case 0xD2: _registers.D = opSET(0x04, _registers.D); break;
            case 0xD3: _registers.E = opSET(0x04, _registers.E); break;
            case 0xD4: _registers.H = opSET(0x04, _registers.H); break;
            case 0xD5: _registers.L = opSET(0x04, _registers.L); break;
            case 0xD6: opWrite8(_registers.HL, opSET(0x04, opRead8(_registers.HL))); break;
            case 0xD7: _registers.A = opSET(0x04, _registers.A); break;

            case 0xD8: _registers.B = opSET(0x08, _registers.B); break;
            case 0xD9: _registers.C = opSET(0x08, _registers.C); break;
            case 0xDA: _registers.D = opSET(0x08, _registers.D); break;
            case 0xDB: _registers.E = opSET(0x08, _registers.E); break;
            case 0xDC: _registers.H = opSET(0x08, _registers.H); break;
            case 0xDD: _registers.L = opSET(0x08, _registers.L); break;
            case 0xDE: opWrite8(_registers.HL, opSET(0x08, opRead8(_registers.HL))); break;
            case 0xDF: _registers.A = opSET(0x08, _registers.A); break;

            case 0xE0: _registers.B = opSET(0x10, _registers.B); break;
            case 0xE1: _registers.C = opSET(0x10, _registers.C); break;
            case 0xE2: _registers.D = opSET(0x10, _registers.D); break;
            case 0xE3: _registers.E = opSET(0x10, _registers.E); break;
            case 0xE4: _registers.H = opSET(0x10, _registers.H); break;
            case 0xE5: _registers.L = opSET(0x10, _registers.L); break;
            case 0xE6: opWrite8(_registers.HL, opSET(0x10, opRead8(_registers.HL))); break;
            case 0xE7: _registers.A = opSET(0x10, _registers.A); break;

            case 0xE8: _registers.B = opSET(0x20, _registers.B); break;
            case 0xE9: _registers.C = opSET(0x20, _registers.C); break;
            case 0xEA: _registers.D = opSET(0x20, _registers.D); break;
            case 0xEB: _registers.E = opSET(0x20, _registers.E); break;
            case 0xEC: _registers.H = opSET(0x20, _registers.H); break;
            case 0xED: _registers.L = opSET(0x20, _registers.L); break;
            case 0xEE: opWrite8(_registers.HL, opSET(0x20, opRead8(_registers.HL))); break;
            case 0xEF: _registers.A = opSET(0x20, _registers.A); break;

            case 0xF0: _registers.B = opSET(0x40, _registers.B); break;
            case 0xF1: _registers.C = opSET(0x40, _registers.C); break;
            case 0xF2: _registers.D = opSET(0x40, _registers.D); break;
            case 0xF3: _registers.E = opSET(0x40, _registers.E); break;
            case 0xF4: _registers.H = opSET(0x40, _registers.H); break;
            case 0xF5: _registers.L = opSET(0x40, _registers.L); break;
            case 0xF6: opWrite8(_registers.HL, opSET(0x40, opRead8(_registers.HL))); break;
            case 0xF7: _registers.A = opSET(0x40, _registers.A); break;

            case 0xF8: _registers.B = opSET(0x80, _registers.B); break;
            case 0xF9: _registers.C = opSET(0x80, _registers.C); break;
            case 0xFA: _registers.D = opSET(0x80, _registers.D); break;
            case 0xFB: _registers.E = opSET(0x80, _registers.E); break;
            case 0xFC: _registers.H = opSET(0x80, _registers.H); break;
            case 0xFD: _registers.L = opSET(0x80, _registers.L); break;
            case 0xFE: opWrite8(_registers.HL, opSET(0x80, opRead8(_registers.HL))); break;
            case 0xFF: _registers.A = opSET(0x80, _registers.A); break;

            default:
                throw new Exception(format("CPU: invalid opcode 0xCB 0x%02X.", opcode));
        }
    }

    // Writes SP to an immediate address.
    private void opLDnnSP() {
        immutable ushort address = opRead16(_registers.PC);
        _registers.PC += 2;
        opWrite8(cast(ushort)(address + 0), cast(ubyte)(_registers.SP >> 0));
        opWrite8(cast(ushort)(address + 1), cast(ubyte)(_registers.SP >> 8));
    }

    // Jumps to an address relative to the current PC.
    private void opJR() {
        _registers.PC += cast(byte)opRead8(_registers.PC++);
        opIO();
    }

    // Conditional version of JR.
    private void opJRcc(immutable ALUFlag mask, immutable bool truth) {
        immutable byte offset = cast(byte)opRead8(_registers.PC++);
        if (cast(bool)(_registers.F & mask) == truth) {
            _registers.PC += offset;
            opIO();
        }
    }

    // Jumps directly to an address.
    private void opJP() {
        _registers.PC = opRead16(_registers.PC);
        opIO();
    }

    // Conditional version of JP.
    private void opJPcc(immutable ALUFlag mask, immutable bool truth) {
        immutable ushort address = opRead16(_registers.PC);
        _registers.PC += 2;

        if (cast(bool)(_registers.F & mask) == truth) {
            _registers.PC = address;
            opIO();
        }
    }

    // Retrieves a new PC value from the stack, to return from a previous CALL.
    private void opRET() {
        _registers.PC = opRead16(_registers.SP);
        _registers.SP += 2;
        opIO();
    }

    // Conditional version of RET.
    private void opRETcc(immutable ALUFlag mask, immutable bool truth) {
        opIO();
        if (cast(bool)(_registers.F & mask) == truth) {
            opRET();
        }
    }

    // Enables interrupts on next cycle and executes RET.
    private void opRETI() {
        opRET();
        _interruptsEnableDelay = true;
    }

    // Stores the current PC on the stack and jumps to an address.
    private void opCALL() {
        immutable ushort address = opRead16(_registers.PC);
        _registers.PC += 2;
        opIO();
        opWrite8(--_registers.SP, cast(ubyte)(_registers.PC >> 8));
        opWrite8(--_registers.SP, cast(ubyte)(_registers.PC >> 0));
        _registers.PC = address;
    }

    // Conditional version of CALL.
    private void opCALLcc(immutable ALUFlag mask, immutable bool truth) {
        immutable ushort address = opRead16(_registers.PC);
        _registers.PC += 2;

        if (cast(bool)(_registers.F & mask) == truth) {
            opIO();
            opWrite8(--_registers.SP, cast(ubyte)(_registers.PC >> 8));
            opWrite8(--_registers.SP, cast(ubyte)(_registers.PC >> 0));
            _registers.PC = address;
        }
    }

    // Restarts from a base address. Basically the same as CALL, but from a fixed address.
    private void opRST(immutable ushort address) {
        opIO();
        opWrite8(--_registers.SP, cast(ubyte)(_registers.PC >> 8));
        opWrite8(--_registers.SP, cast(ubyte)(_registers.PC >> 0));
        _registers.PC = address;
    }

    // Resets a bit.
    private ubyte opRES(immutable ubyte mask, immutable ubyte value) {
        return cast(ubyte)(value & ~cast(int)mask);
    }

    // Sets a bit.
    private ubyte opSET(immutable ubyte mask, immutable ubyte value) {
        return cast(ubyte)(value | mask);
    }

    // Tests if a bit is set.
    private void opBIT(immutable ubyte mask, immutable ubyte value) {
        resetFlag(ALUFlag.SUBTRACT);
        setFlag(ALUFlag.CARRY_HALF);

        if (value & mask) {
            resetFlag(ALUFlag.ZERO);
        } else {
            setFlag(ALUFlag.ZERO);
        }
    }

    // Inverts the carry flag.
    private void opCCF() {
        resetFlag(ALUFlag.SUBTRACT);
        resetFlag(ALUFlag.CARRY_HALF);

        if (_registers.F & ALUFlag.CARRY) {
            _registers.F &= ~cast(int)ALUFlag.CARRY;
        } else {
            _registers.F |= ALUFlag.CARRY;
        }
    }

    // Sets the carry flag.
    private void opSCF() {
        resetFlag(ALUFlag.SUBTRACT);
        resetFlag(ALUFlag.CARRY_HALF);
        setFlag(ALUFlag.CARRY);
    }

    // Complements a value, meaning all it's bits are flipped.
    private ubyte opCPL(immutable ubyte value) {
        _registers.F |= ALUFlag.SUBTRACT | ALUFlag.CARRY_HALF;
        return value ^ 0xFF;
    }

    // Decimal adjusts a value.
    private ubyte opDAA(ubyte value) {
        if (!(_registers.F & ALUFlag.SUBTRACT)) {
            if ((_registers.F & ALUFlag.CARRY) || value > 0x99) {
                value += 0x60;
                _registers.F |= ALUFlag.CARRY;
            }
            if (_registers.F & ALUFlag.CARRY_HALF || (value & 0xF) > 0x9) {
                value += 0x06;
                _registers.F &= ~cast(int)ALUFlag.CARRY_HALF;
            }

        } else if ((_registers.F & ALUFlag.CARRY) && (_registers.F & ALUFlag.CARRY_HALF)) {
            value += 0x9A;
            _registers.F &= ~cast(int)ALUFlag.CARRY_HALF;

        } else if (_registers.F & ALUFlag.CARRY) {
            value += 0xA0;

        } else if (_registers.F & ALUFlag.CARRY_HALF) {
            value += 0xFA;
            _registers.F &= ~cast(int)ALUFlag.CARRY_HALF;
        }

        if (!value) {
            _registers.F |= ALUFlag.ZERO;
        } else {
            _registers.F &= ~cast(int)ALUFlag.ZERO;
        }

        return value;
    }

    // Swaps the two nibbles of a byte.
    private ubyte opSWAP(immutable ubyte value) {
        immutable ubyte result = ((value & 0xF) << 4) | ((value & 0xF0) >> 4);

        _registers.F = 0;
        if (!result) {
            setFlag(ALUFlag.ZERO);
        }

        return result;
    }

    // ANDs two values.
    private ubyte opAND(immutable ubyte value1, immutable ubyte value2) {
        immutable ubyte result = value1 & value2;

        _registers.F = 0;
        if (!result) {
            setFlag(ALUFlag.ZERO);
        } else {
            resetFlag(ALUFlag.ZERO);
        }
        setFlag(ALUFlag.CARRY_HALF);

        return result;
    }

    // ORs two values.
    private ubyte opOR(immutable ubyte value1, immutable ubyte value2) {
        immutable ubyte result = value1 | value2;

        _registers.F = 0;
        if (!result) {
            setFlag(ALUFlag.ZERO);
        } else {
            resetFlag(ALUFlag.ZERO);
        }

        return result;
    }

    // XORs two values.
    private ubyte opXOR(immutable ubyte value1, immutable ubyte value2) {
        immutable ubyte result = value1 ^ value2;

        _registers.F = 0;
        if (!result) {
            setFlag(ALUFlag.ZERO);
        } else {
            resetFlag(ALUFlag.ZERO);
        }

        return result;
    }

    // Pushes a value to the current stack pointer, decrease stack pointer.
    private void opPUSH(immutable ushort value) {
        opWrite8(--_registers.SP, cast(ubyte)(value >> 8));
        opWrite8(--_registers.SP, cast(ubyte)(value >> 0));
        opIO();
    }

    // Pops a value from the current stack pointer, increase stack pointer.
    private ushort opPOP() {
        immutable ushort value = opRead16(_registers.SP);
        _registers.SP += 2;
        return value;
    }

    // Loads SP+n into HL.
    private void opHLSP() {
        opIO();

        immutable byte value = cast(byte)opRead8(_registers.PC++);
        _registers.HL = cast(ushort)(_registers.SP + value);

        _registers.F = 0;
        if (((_registers.SP ^ value ^ _registers.HL) & 0x100) == 0x100) {
            setFlag(ALUFlag.CARRY);
        }
        if (((_registers.SP ^ value ^ _registers.HL) & 0x10) == 0x10) {
            setFlag(ALUFlag.CARRY_HALF);
        }
    }

    // Add value to SP.
    private void opSPADD() {
        opIO();
        opIO();

        immutable byte value = cast(byte)opRead8(_registers.PC++);
        immutable int result = cast(ushort)(_registers.SP + value);

        _registers.F = 0;
        if (((_registers.SP ^ value ^ (result & 0xFFFF)) & 0x100) == 0x100) {
            setFlag(ALUFlag.CARRY);
        }
        if (((_registers.SP ^ value ^ (result & 0xFFFF)) & 0x10) == 0x10) {
            setFlag(ALUFlag.CARRY_HALF);
        }

        _registers.SP = cast(ushort)result;
    }

    // Adds 2 16-bit values.
    private ushort opADDHL(immutable ushort value1, immutable ushort value2) {
        opIO();

        resetFlag(ALUFlag.SUBTRACT);

        if (((value1 & 0xFFF) + (value2 & 0xFFF)) & 0x1000) {
            setFlag(ALUFlag.CARRY_HALF);
        } else {
            resetFlag(ALUFlag.CARRY_HALF);
        }

        if (value1 + value2 > 0xFFFF) {
            setFlag(ALUFlag.CARRY);
        } else {
            resetFlag(ALUFlag.CARRY);
        }

        return cast(ushort)(value1 + value2);
    }

    // Adds two values.
    private ubyte opADD(immutable ubyte value1, immutable ubyte value2) {
        immutable int result = value1 + value2;
        immutable int carry = value1 ^ value2 ^ result;

        _registers.F = 0;
        if (!cast(ubyte)result) {
            setFlag(ALUFlag.ZERO);
        }
        if (carry & 0x100) {
            setFlag(ALUFlag.CARRY);
        }
        if (carry & 0x10) {
            setFlag(ALUFlag.CARRY_HALF);
        }

        return cast(ubyte)result;
    }

    // Adds two values and the carry flag.
    private ubyte opADC(immutable ubyte value1, immutable ubyte value2) {
        immutable ubyte carry = _registers.F & ALUFlag.CARRY ? 1 : 0;
        immutable int result = value1 + value2 + carry;

        _registers.F = 0;
        if (!cast(ubyte)result) {
            setFlag(ALUFlag.ZERO);
        }
        if (result > 0xFF) {
            setFlag(ALUFlag.CARRY);
        }
        if (((value1 & 0x0F) + (value2 & 0x0F) + carry) > 0x0F) {
            setFlag(ALUFlag.CARRY_HALF);
        }

        return cast(ubyte)result;
    }

    // Subtracts two values.
    private ubyte opSUB(immutable ubyte value1, immutable ubyte value2) {
        immutable int result = value1 - value2;
        immutable int carry = value1 ^ value2 ^ result;

        _registers.F = ALUFlag.SUBTRACT;
        if (!cast(ubyte)result) {
            setFlag(ALUFlag.ZERO);
        }
        if (carry & 0x100) {
            setFlag(ALUFlag.CARRY);
        }
        if (carry & 0x10) {
            setFlag(ALUFlag.CARRY_HALF);
        }

        return cast(ubyte)result;
    }

    // Subtracts two values and the carry flag.
    private ubyte opSBC(immutable ubyte value1, immutable ubyte value2) {
        immutable ubyte carry = (_registers.F & ALUFlag.CARRY) ? 1 : 0;
        immutable int result = value1 - value2 - carry;

        _registers.F = ALUFlag.SUBTRACT;
        if (!cast(ubyte)result) {
            setFlag(ALUFlag.ZERO);
        }
        if (result < 0) {
            setFlag(ALUFlag.CARRY);
        }
        if (((value1 & 0x0F) - (value2 & 0x0F) - carry) < 0) {
            setFlag(ALUFlag.CARRY_HALF);
        }

        return cast(ubyte)result;
    }

    // Compares two values.
    private void opCP(immutable ubyte value1, immutable ubyte value2) {
        _registers.F = 0;

        setFlag(ALUFlag.SUBTRACT);

        if (((value1 - value2) & 0xF) > (value1 & 0xF)) {
            setFlag(ALUFlag.CARRY_HALF);
        }

        if (value1 < value2) {
            setFlag(ALUFlag.CARRY);
        } else if (value1 == value2) {
            setFlag(ALUFlag.ZERO);
        }
    }

    // Increments a value.
    private ubyte opINC(immutable ubyte value) {
        immutable ubyte result = cast(ubyte)(value + cast(ubyte)1);

        if ((result & 0x0F) == 0) {
            setFlag(ALUFlag.CARRY_HALF);
        } else {
            resetFlag(ALUFlag.CARRY_HALF);
        }

        resetFlag(ALUFlag.SUBTRACT);

        if (result == 0) {
            setFlag(ALUFlag.ZERO);
        } else {
            resetFlag(ALUFlag.ZERO);
        }

        return result;
    }

    // Decrements a value.
    private ubyte opDEC(immutable ubyte value) {
        immutable ubyte result = cast(ubyte)(value - cast(ubyte)1);

        if ((result & 0x0F) == 0xF) {
            setFlag(ALUFlag.CARRY_HALF);
        } else {
            resetFlag(ALUFlag.CARRY_HALF);
        }

        setFlag(ALUFlag.SUBTRACT);

        if (result == 0) {
            setFlag(ALUFlag.ZERO);
        } else {
            resetFlag(ALUFlag.ZERO);
        }

        return result;
    }

    // Rotates a value left into the carry flag.
    private ubyte opRLC(immutable ubyte value, immutable bool setZero) {
        immutable bool carry = (value & 0x80) ? true : false;
        ubyte result = cast(ubyte)(value << 1);

        _registers.F = 0;
        if (carry) {
            setFlag(ALUFlag.CARRY);
            result ^= 0x01;
        }
        if (setZero && !result) {
            setFlag(ALUFlag.ZERO);
        }

        return result;
    }

    // Rotates a value left through the carry flag.
    private ubyte opRL(immutable ubyte value, immutable bool setZero) {
        immutable bool carry = (value & 0x80) ? true : false;
        ubyte result = cast(ubyte)(value << 1);

        if (_registers.F & ALUFlag.CARRY) {
            result ^= 0x01;
        }

        _registers.F = 0;
        if (carry) {
            setFlag(ALUFlag.CARRY);
        }
        if (setZero && !result) {
            setFlag(ALUFlag.ZERO);
        }

        return result;
    }

    // Rotates a value right into the carry flag.
    private ubyte opRRC(immutable ubyte value, immutable bool setZero) {
        immutable bool carry = (value & 0x01) ? true : false;
        ubyte result = value >> 1;

        _registers.F = 0;
        if (carry) {
            setFlag(ALUFlag.CARRY);
            result ^= 0x80;
        }
        if (setZero && !result) {
            setFlag(ALUFlag.ZERO);
        }

        return result;
    }

    // Rotates a value right through the carry flag.
    private ubyte opRR(immutable ubyte value, immutable bool setZero) {
        immutable bool carry = (value & 0x01) ? true : false;
        ubyte result = value >> 1;

        if (_registers.F & ALUFlag.CARRY) {
            result ^= 0x80;
        }

        _registers.F = 0;
        if (carry) {
            setFlag(ALUFlag.CARRY);
        }
        if (setZero && !result) {
            setFlag(ALUFlag.ZERO);
        }

        return result;
    }

    // Shifts a value left into the carry flag, resets bit 0.
    private ubyte opSLA(immutable ubyte value) {
        immutable bool carry = (value & 0x80) ? true : false;
        immutable ubyte result = cast(ubyte)(value << 1);

        _registers.F = 0;
        if (!result) {
            setFlag(ALUFlag.ZERO);
        }
        if (carry) {
            setFlag(ALUFlag.CARRY);
        }

        return result;
    }

    // Shifts a value right into the carry flag, keeps bit 7.
    private ubyte opSRA(immutable ubyte value) {
        immutable bool carry = (value & 0x01) ? true : false;
        immutable ubyte result = cast(ubyte)((value >> 1) | (value & 0x80));

        _registers.F = 0;
        if (!result) {
            setFlag(ALUFlag.ZERO);
        }
        if (carry) {
            setFlag(ALUFlag.CARRY);
        }

        return result;
    }

    // Shifts a value right into the carry flag, resets bit 7.
    private ubyte opSRL(immutable ubyte value) {
        immutable bool carry = (value & 0x01) ? true : false;
        immutable ubyte result = value >> 1;

        _registers.F = 0;
        if (!result) {
            setFlag(ALUFlag.ZERO);
        }
        if (carry) {
            setFlag(ALUFlag.CARRY);
        }

        return result;
    }

    // Resets a single ALU flag.
    private void resetFlag(immutable ALUFlag flag) {
        _registers.F &= ~cast(int)flag;
    }

    // Sets a single ALU flg.
    private void setFlag(immutable ALUFlag flag) {
        _registers.F |= flag;
    }

    // Gets the state of a single ALU flag.
    private bool getFlag(immutable ALUFlag flag) {
        return ((_registers.F & flag) != 0);
    }

    pragma(inline, true)
    private bool isAddressInDMAUse(immutable ushort address) {
        if (!_dmaCycles|| address >= 0xFE00) {
            return false;
        }

        return _mmu.busForAddress(address) == _mmu.busForAddress(_dmaCurrentSrc);
    }

    @property
    public ref Registers registers() {
        return _registers;
    }

    @property
    public ubyte interruptFlags() {
        return _interruptFlags;
    }

    @property
    public void interruptFlags(immutable ubyte flags) {
        _interruptFlags = cast(InterruptFlag)(flags & 0x1F);
    }

    @property
    public ubyte interruptsEnabled() {
        return _interruptsEnabled;
    }

    @property
    public void interruptsEnabled(immutable ubyte flags) {
        _interruptsEnabled = cast(InterruptFlag)(flags & 0x1F);
    }

    @property
    public bool interruptsMasterEnable() {
        return _interruptsMasterEnable;
    }

    @property
    public State state() {
        return _state;
    }

    @property
    public void dmaAddress(immutable ubyte value) {
        
        // 160 + 8 setup cycles.
        if (value < 0xF2) {
            _dmaCycles = 168;
        }

        _dmaAddress = value;
        _dmaCurrentSrc = value << 8;
        _dmaCurrentDest = 0xFE00;

        stdout.flush();
    }

    @property
    public ubyte dmaAddress() {

        // While DMA is active, this register returns the last byte written.
        if (_dmaCycles && _dmaCycles < 160) {
            stdout.flush();
            return _mmu.read8(_dmaCurrentSrc);
        }

        stdout.flush();
        return _dmaAddress;
    }
}
