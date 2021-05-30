module Core.Disassembler;

import std.stdio;
import std.string;

import Core.MMU;


public final class Disassembler {
    private MMU _mmu;
    private ushort _pc;

    public this(MMU mmu) {
        _mmu = mmu;
    }

    public void disassemble(immutable ushort address, immutable ushort opCount) {
        _pc = address;

        ushort op = 0;
        while (op < opCount) {
            immutable ushort current = _pc;
            immutable ubyte opcode = _mmu.read8(_pc++);
            writefln("$%04X: %s", current, decode(opcode));
            op++;
        }
    }

    pragma(inline, true)
    private string read8() {
        immutable ubyte value = _mmu.read8(_pc++);
        return format("$%02X", value);
    }

    pragma(inline, true)
    private string read16() {
        immutable ushort value = _mmu.read16(_pc);
        _pc += 2;
        return format("$%04X", value);
    }

    private string decode(const ubyte opcode) {
        switch (opcode) {
            case 0x06: return format("LD   B, %s", read8());
            case 0x0E: return format("LD   C, %s", read8());
            case 0x16: return format("LD   D, %s", read8());
            case 0x1E: return format("LD   E, %s", read8());
            case 0x26: return format("LD   H, %s", read8());
            case 0x2E: return format("LD   L, %s", read8());
            case 0x36: return format("LD   (HL), %s", read8());
            case 0x3E: return format("LD   A, %s", read8());

            case 0x0A: return format("LD   A, (BC)");
            case 0x1A: return format("LD   A, (DE)");
            case 0x7E: return format("LD   A, (HL)");
            case 0xFA: return format("LD   A, (%s)", read16());

            case 0x40: return format("LD   B, B");
            case 0x41: return format("LD   B, C");
            case 0x42: return format("LD   B, D");
            case 0x43: return format("LD   B, E");
            case 0x44: return format("LD   B, H");
            case 0x45: return format("LD   B, L");
            case 0x46: return format("LD   B, (HL)");

            case 0x48: return format("LD   C, B");
            case 0x49: return format("LD   C, C");
            case 0x4A: return format("LD   C, D");
            case 0x4B: return format("LD   C, E");
            case 0x4C: return format("LD   C, H");
            case 0x4D: return format("LD   C, L");
            case 0x4E: return format("LD   C, (HL)");

            case 0x50: return format("LD   D, B");
            case 0x51: return format("LD   D, C");
            case 0x52: return format("LD   D, D");
            case 0x53: return format("LD   D, E");
            case 0x54: return format("LD   D, H");
            case 0x55: return format("LD   D, L");
            case 0x56: return format("LD   D, (HL)");

            case 0x58: return format("LD   E, B");
            case 0x59: return format("LD   E, C");
            case 0x5A: return format("LD   E, D");
            case 0x5B: return format("LD   E, E");
            case 0x5C: return format("LD   E, H");
            case 0x5D: return format("LD   E, L");
            case 0x5E: return format("LD   E, (HL)");

            case 0x60: return format("LD   H, B");
            case 0x61: return format("LD   H, C");
            case 0x62: return format("LD   H, D");
            case 0x63: return format("LD   H, E");
            case 0x64: return format("LD   H, H");
            case 0x65: return format("LD   H, L");
            case 0x66: return format("LD   H, (HL)");

            case 0x68: return format("LD   L, B");
            case 0x69: return format("LD   L, C");
            case 0x6A: return format("LD   L, D");
            case 0x6B: return format("LD   L, E");
            case 0x6C: return format("LD   L, H");
            case 0x6D: return format("LD   L, L");
            case 0x6E: return format("LD   L, (HL)");

            case 0x70: return format("LD   (HL), B");
            case 0x71: return format("LD   (HL), C");
            case 0x72: return format("LD   (HL), D");
            case 0x73: return format("LD   (HL), E");
            case 0x74: return format("LD   (HL), H");
            case 0x75: return format("LD   (HL), L");
            
            case 0x78: return format("LD   A, B");
            case 0x79: return format("LD   A, C");
            case 0x7A: return format("LD   A, D");
            case 0x7B: return format("LD   A, E");
            case 0x7C: return format("LD   A, H");
            case 0x7D: return format("LD   A, L");
            case 0x7F: return format("LD   A, A");

            case 0x47: return format("LD   B, A");
            case 0x4F: return format("LD   C, A");
            case 0x57: return format("LD   D, A");
            case 0x5F: return format("LD   E, A");
            case 0x67: return format("LD   H, A");
            case 0x6F: return format("LD   L, A");
            
            case 0x02: return format("LD   (BC), A");
            case 0x12: return format("LD   (DE), A");
            case 0x77: return format("LD   (HL), A");
            case 0xEA: return format("LD   (%s), A", read16());

            case 0xF2: return format("LD   C, ($FF00 + %s)", read8());
            case 0xE2: return format("LD   ($FF00 + %s), C", read8());
            case 0xF0: return format("LD   A, ($FF00 + %s)", read8());
            case 0xE0: return format("LD   ($FF00 + %s), A", read8());

            case 0x3A: return format("LD   A, (HL-)");
            case 0x32: return format("LD   (HL-), A");
            case 0x2A: return format("LD   A, (HL+)");
            case 0x22: return format("LD   (HL+), A");

            case 0x01: return format("LD   BC, %s", read16());
            case 0x11: return format("LD   DE, %s", read16());
            case 0x21: return format("LD   HL, %s", read16());
            case 0x31: return format("LD   SP, %s", read16());

            case 0xF9: return format("LD   SP, HL");
            case 0xF8: return format("LD   HL, SP + %s", read8());
            case 0x08: return format("LD   (%s), SP", read16());

            case 0xF5: return format("PUSH AF");
            case 0xC5: return format("PUSH BC");
            case 0xD5: return format("PUSH DE");
            case 0xE5: return format("PUSH HL");

            case 0xF1: return format("POP  AF");
            case 0xC1: return format("POP  BC");
            case 0xD1: return format("POP  DE");
            case 0xE1: return format("POP  HL");

            case 0x80: return format("ADD  A, B");
            case 0x81: return format("ADD  A, C");
            case 0x82: return format("ADD  A, D");
            case 0x83: return format("ADD  A, E");
            case 0x84: return format("ADD  A, H");
            case 0x85: return format("ADD  A, L");
            case 0x86: return format("ADD  A, (HL)");
            case 0x87: return format("ADD  A, A");
            case 0xC6: return format("ADD  A, %s", read8());

            case 0x88: return format("ADC  A, B");
            case 0x89: return format("ADC  A, C");
            case 0x8A: return format("ADC  A, D");
            case 0x8B: return format("ADC  A, E");
            case 0x8C: return format("ADC  A, H");
            case 0x8D: return format("ADC  A, L");
            case 0x8E: return format("ADC  A, (HL)");
            case 0x8F: return format("ADC  A, A");
            case 0xCE: return format("ADC  A, %s", read8());

            case 0x90: return format("SUB  A, B");
            case 0x91: return format("SUB  A, C");
            case 0x92: return format("SUB  A, D");
            case 0x93: return format("SUB  A, E");
            case 0x94: return format("SUB  A, H");
            case 0x95: return format("SUB  A, L");
            case 0x96: return format("SUB  A, (HL)");
            case 0x97: return format("SUB  A, A");
            case 0xD6: return format("SUB  A, %s", read8());

            case 0x98: return format("SBC  A, B");
            case 0x99: return format("SBC  A, C");
            case 0x9A: return format("SBC  A, D");
            case 0x9B: return format("SBC  A, E");
            case 0x9C: return format("SBC  A, H");
            case 0x9D: return format("SBC  A, L");
            case 0x9E: return format("SBC  A, (HL)");
            case 0x9F: return format("SBC  A, A");
            case 0xDE: return format("SBC  A, %s", read8());

            case 0xA0: return format("AND  A, B");
            case 0xA1: return format("AND  A, C");
            case 0xA2: return format("AND  A, D");
            case 0xA3: return format("AND  A, E");
            case 0xA4: return format("AND  A, H");
            case 0xA5: return format("AND  A, L");
            case 0xA6: return format("AND  A, (HL)");
            case 0xA7: return format("AND  A, A");
            case 0xE6: return format("AND  A, %s", read8());

            case 0xB0: return format("OR   A, B");
            case 0xB1: return format("OR   A, C");
            case 0xB2: return format("OR   A, D");
            case 0xB3: return format("OR   A, E");
            case 0xB4: return format("OR   A, H");
            case 0xB5: return format("OR   A, L");
            case 0xB6: return format("OR   A, (HL)");
            case 0xB7: return format("OR   A, A");
            case 0xF6: return format("OR   A, %s", read8());

            case 0xA8: return format("XOR  A, B");
            case 0xA9: return format("XOR  A, C");
            case 0xAA: return format("XOR  A, D");
            case 0xAB: return format("XOR  A, E");
            case 0xAC: return format("XOR  A, H");
            case 0xAD: return format("XOR  A, L");
            case 0xAE: return format("XOR  A, (HL)");
            case 0xAF: return format("XOR  A, A");
            case 0xEE: return format("XOR  A, %s", read8());

            case 0xB8: return format("CP   A, B");
            case 0xB9: return format("CP   A, C");
            case 0xBA: return format("CP   A, D");
            case 0xBB: return format("CP   A, E");
            case 0xBC: return format("CP   A, H");
            case 0xBD: return format("CP   A, L");
            case 0xBE: return format("CP   A, (HL)");
            case 0xBF: return format("CP   A, A");
            case 0xFE: return format("CP   A, %s", read8());

            case 0x04: return format("INC  B");
            case 0x0C: return format("INC  C");
            case 0x14: return format("INC  D");
            case 0x1C: return format("INC  E");
            case 0x24: return format("INC  H");
            case 0x2C: return format("INC  L");
            case 0x34: return format("INC  (HL)");
            case 0x3C: return format("INC  A");

            case 0x05: return format("DEC  B");
            case 0x0D: return format("DEC  C");
            case 0x15: return format("DEC  D");
            case 0x1D: return format("DEC  E");
            case 0x25: return format("DEC  H");
            case 0x2D: return format("DEC  L");
            case 0x35: return format("DEC  (HL)");
            case 0x3D: return format("DEC  A");

            case 0x09: return format("ADD  HL, BC");
            case 0x19: return format("ADD  HL, DE");
            case 0x29: return format("ADD  HL, HL");
            case 0x39: return format("ADD  HL, SP");
            case 0xE8: return format("ADD  SP, %s", read8());

            case 0x03: return format("INC  BC");
            case 0x13: return format("INC  DE");
            case 0x23: return format("INC  HL");
            case 0x33: return format("INC  SP");

            case 0x0B: return format("DEC  BC");
            case 0x1B: return format("DEC  DE");
            case 0x2B: return format("DEC  HL");
            case 0x3B: return format("DEC  SP");

            case 0x27: return format("DA   A");
            case 0x2F: return format("CPL  A");
            case 0x3F: return format("CCF");
            case 0x37: return format("SCF");

            case 0x00: return format("NOP");
            case 0x76: return format("HALT");
            case 0x10: return format("STOP");
            case 0xF3: return format("DI");
            case 0xFB: return format("EI");

            case 0x07: return format("RLC  A");
            case 0x17: return format("RL   A");
            case 0x0F: return format("RRC  A");
            case 0x1F: return format("RR   A");

            case 0xC3: return format("JP   %s", read16());
            case 0xC2: return format("JP   NZ, %s", read16());
            case 0xCA: return format("JP   Z, %s", read16());
            case 0xD2: return format("JP   NC, %s", read16());
            case 0xDa: return format("JP   C, %s", read16());
            case 0xE9: return format("JP   (HL)");

            case 0x18: return format("JR   %s", read8());
            case 0x20: return format("JR   NZ, %s", read8());
            case 0x28: return format("JR   Z, %s", read8());
            case 0x30: return format("JR   NC, %s", read8());
            case 0x38: return format("JR   C, %s", read8());

            case 0xCD: return format("CALL %s", read16());
            case 0xC4: return format("CALL NZ, %s", read16());
            case 0xCC: return format("CALL Z, %s", read16());
            case 0xD4: return format("CALL NC, %s", read16());
            case 0xDC: return format("CALL C, %s", read16());

            case 0xC7: return format("RST  $00");
            case 0xCF: return format("RST  $08");
            case 0xDF: return format("RST  $18");
            case 0xE7: return format("RST  $20");
            case 0xEF: return format("RST  $28");
            case 0xF7: return format("RST  $30");
            case 0xFF: return format("RST  $38");

            case 0xC9: return format("RET");
            case 0xD9: return format("RETI");
            case 0xC0: return format("RET  NZ");
            case 0xC8: return format("RET  Z");
            case 0xD0: return format("RET  NC");
            case 0xD8: return format("RET  C");

            case 0xCB: return decodeExt(_mmu.read8(_pc++));

            default:
                return format("???? $%02X", opcode);
        }
    }

    //pragma(inline, true)
    private string decodeExt(immutable ubyte opcode) {

        switch (opcode) {
            case 0x30: return format("SWAP B");
            case 0x31: return format("SWAP C");
            case 0x32: return format("SWAP D");
            case 0x33: return format("SWAP E");
            case 0x34: return format("SWAP H");
            case 0x35: return format("SWAP L");
            case 0x36: return format("SWAP (HL)");
            case 0x37: return format("SWAP A");

            case 0x00: return format("RLC  B");
            case 0x01: return format("RLC  C");
            case 0x02: return format("RLC  D");
            case 0x03: return format("RLC  E");
            case 0x04: return format("RLC  H");
            case 0x05: return format("RLC  L");
            case 0x06: return format("RLC  (HL)");
            case 0x07: return format("RLC  A");

            case 0x10: return format("RL   B");
            case 0x11: return format("RL   C");
            case 0x12: return format("RL   D");
            case 0x13: return format("RL   E");
            case 0x14: return format("RL   H");
            case 0x15: return format("RL   L");
            case 0x16: return format("RL   (HL)");
            case 0x17: return format("RL   A");

            case 0x08: return format("RRC  B");
            case 0x09: return format("RRC  C");
            case 0x0A: return format("RRC  D");
            case 0x0B: return format("RRC  E");
            case 0x0C: return format("RRC  H");
            case 0x0D: return format("RRC  L");
            case 0x0E: return format("RRC  (HL)");
            case 0x0F: return format("RRC  A");

            case 0x18: return format("RR   B");
            case 0x19: return format("RR   C");
            case 0x1A: return format("RR   D");
            case 0x1B: return format("RR   E");
            case 0x1C: return format("RR   H");
            case 0x1D: return format("RR   L");
            case 0x1E: return format("RR   (HL)");
            case 0x1F: return format("RR   A");

            case 0x20: return format("SLA  B");
            case 0x21: return format("SLA  C");
            case 0x22: return format("SLA  D");
            case 0x23: return format("SLA  E");
            case 0x24: return format("SLA  H");
            case 0x25: return format("SLA  L");
            case 0x26: return format("SLA  (HL)");
            case 0x27: return format("SLA  A");

            case 0x2F: return format("SRA  B");
            case 0x28: return format("SRA  C");
            case 0x29: return format("SRA  D");
            case 0x2A: return format("SRA  E");
            case 0x2B: return format("SRA  H");
            case 0x2C: return format("SRA  L");
            case 0x2D: return format("SRA  (HL)");
            case 0x2E: return format("SRA  A");
            
            case 0x38: return format("SRL  B");
            case 0x39: return format("SRL  C");
            case 0x3A: return format("SRL  D");
            case 0x3B: return format("SRL  E");
            case 0x3C: return format("SRL  H");
            case 0x3D: return format("SRL  L");
            case 0x3E: return format("SRL  (HL)");
            case 0x3F: return format("SRL  A");

            case 0x40: return format("BIT  0, B");
            case 0x41: return format("BIT  0, C");
            case 0x42: return format("BIT  0, D");
            case 0x43: return format("BIT  0, E");
            case 0x44: return format("BIT  0, H");
            case 0x45: return format("BIT  0, L");
            case 0x46: return format("BIT  0, (HL)");
            case 0x47: return format("BIT  0, A");

            case 0x48: return format("BIT  1, B");
            case 0x49: return format("BIT  1, C");
            case 0x4A: return format("BIT  1, D");
            case 0x4B: return format("BIT  1, E");
            case 0x4C: return format("BIT  1, H");
            case 0x4D: return format("BIT  1, L");
            case 0x4E: return format("BIT  1, (HL)");
            case 0x4F: return format("BIT  1, A");

            case 0x50: return format("BIT  2, B");
            case 0x51: return format("BIT  2, C");
            case 0x52: return format("BIT  2, D");
            case 0x53: return format("BIT  2, E");
            case 0x54: return format("BIT  2, H");
            case 0x55: return format("BIT  2, L");
            case 0x56: return format("BIT  2, (HL)");
            case 0x57: return format("BIT  2, A");

            case 0x58: return format("BIT  3, B");
            case 0x59: return format("BIT  3, C");
            case 0x5A: return format("BIT  3, D");
            case 0x5B: return format("BIT  3, E");
            case 0x5C: return format("BIT  3, H");
            case 0x5D: return format("BIT  3, L");
            case 0x5E: return format("BIT  3, (HL)");
            case 0x5F: return format("BIT  3, A");

            case 0x60: return format("BIT  4, B");
            case 0x61: return format("BIT  4, C");
            case 0x62: return format("BIT  4, D");
            case 0x63: return format("BIT  4, E");
            case 0x64: return format("BIT  4, H");
            case 0x65: return format("BIT  4, L");
            case 0x66: return format("BIT  4, (HL)");
            case 0x67: return format("BIT  4, A");

            case 0x68: return format("BIT  5, B");
            case 0x69: return format("BIT  5, C");
            case 0x6A: return format("BIT  5, D");
            case 0x6B: return format("BIT  5, E");
            case 0x6C: return format("BIT  5, H");
            case 0x6D: return format("BIT  5, L");
            case 0x6E: return format("BIT  5, (HL)");
            case 0x6F: return format("BIT  5, A");

            case 0x70: return format("BIT  6, B");
            case 0x71: return format("BIT  6, C");
            case 0x72: return format("BIT  6, D");
            case 0x73: return format("BIT  6, E");
            case 0x74: return format("BIT  6, H");
            case 0x75: return format("BIT  6, L");
            case 0x76: return format("BIT  6, (HL)");
            case 0x77: return format("BIT  6, A");

            case 0x78: return format("BIT  7, B");
            case 0x79: return format("BIT  7, C");
            case 0x7A: return format("BIT  7, D");
            case 0x7B: return format("BIT  7, E");
            case 0x7C: return format("BIT  7, H");
            case 0x7D: return format("BIT  7, L");
            case 0x7E: return format("BIT  7, (HL)");
            case 0x7F: return format("BIT  7, A");

            case 0x80: return format("RES  0, B");
            case 0x81: return format("RES  0, C");
            case 0x82: return format("RES  0, D");
            case 0x83: return format("RES  0, E");
            case 0x84: return format("RES  0, H");
            case 0x85: return format("RES  0, L");
            case 0x86: return format("RES  0, (HL)");
            case 0x87: return format("RES  0, A");

            case 0x88: return format("RES  1, B");
            case 0x89: return format("RES  1, C");
            case 0x8A: return format("RES  1, D");
            case 0x8B: return format("RES  1, E");
            case 0x8C: return format("RES  1, H");
            case 0x8D: return format("RES  1, L");
            case 0x8E: return format("RES  1, (HL)");
            case 0x8F: return format("RES  1, A");

            case 0x90: return format("RES  2, B");
            case 0x91: return format("RES  2, C");
            case 0x92: return format("RES  2, D");
            case 0x93: return format("RES  2, E");
            case 0x94: return format("RES  2, H");
            case 0x95: return format("RES  2, L");
            case 0x96: return format("RES  2, (HL)");
            case 0x97: return format("RES  2, A");

            case 0x98: return format("RES  3, B");
            case 0x99: return format("RES  3, C");
            case 0x9A: return format("RES  3, D");
            case 0x9B: return format("RES  3, E");
            case 0x9C: return format("RES  3, H");
            case 0x9D: return format("RES  3, L");
            case 0x9E: return format("RES  3, (HL)");
            case 0x9F: return format("RES  3, A");

            case 0xA0: return format("RES  4, B");
            case 0xA1: return format("RES  4, C");
            case 0xA2: return format("RES  4, D");
            case 0xA3: return format("RES  4, E");
            case 0xA4: return format("RES  4, H");
            case 0xA5: return format("RES  4, L");
            case 0xA6: return format("RES  4, (HL)");
            case 0xA7: return format("RES  4, A");

            case 0xA8: return format("RES  5, B");
            case 0xA9: return format("RES  5, C");
            case 0xAA: return format("RES  5, D");
            case 0xAB: return format("RES  5, E");
            case 0xAC: return format("RES  5, H");
            case 0xAD: return format("RES  5, L");
            case 0xAE: return format("RES  5, (HL)");
            case 0xAF: return format("RES  5, A");

            case 0xB0: return format("RES  6, B");
            case 0xB1: return format("RES  6, C");
            case 0xB2: return format("RES  6, D");
            case 0xB3: return format("RES  6, E");
            case 0xB4: return format("RES  6, H");
            case 0xB5: return format("RES  6, L");
            case 0xB6: return format("RES  6, (HL)");
            case 0xB7: return format("RES  6, A");

            case 0xB8: return format("RES  7, B");
            case 0xB9: return format("RES  7, C");
            case 0xBA: return format("RES  7, D");
            case 0xBB: return format("RES  7, E");
            case 0xBC: return format("RES  7, H");
            case 0xBD: return format("RES  7, L");
            case 0xBE: return format("RES  7, (HL)");
            case 0xBF: return format("RES  7, A");

            case 0xC0: return format("SET  0, B");
            case 0xC1: return format("SET  0, C");
            case 0xC2: return format("SET  0, D");
            case 0xC3: return format("SET  0, E");
            case 0xC4: return format("SET  0, H");
            case 0xC5: return format("SET  0, L");
            case 0xC6: return format("SET  0, (HL)");
            case 0xC7: return format("SET  0, A");

            case 0xC8: return format("SET  1, B");
            case 0xC9: return format("SET  1, C");
            case 0xCA: return format("SET  1, D");
            case 0xCB: return format("SET  1, E");
            case 0xCC: return format("SET  1, H");
            case 0xCD: return format("SET  1, L");
            case 0xCE: return format("SET  1, (HL)");
            case 0xCF: return format("SET  1, A");

            case 0xD0: return format("SET  2, B");
            case 0xD1: return format("SET  2, C");
            case 0xD2: return format("SET  2, D");
            case 0xD3: return format("SET  2, E");
            case 0xD4: return format("SET  2, H");
            case 0xD5: return format("SET  2, L");
            case 0xD6: return format("SET  2, (HL)");
            case 0xD7: return format("SET  2, A");

            case 0xD8: return format("SET  3, B");
            case 0xD9: return format("SET  3, C");
            case 0xDA: return format("SET  3, D");
            case 0xDB: return format("SET  3, E");
            case 0xDC: return format("SET  3, H");
            case 0xDD: return format("SET  3, L");
            case 0xDE: return format("SET  3, (HL)");
            case 0xDF: return format("SET  3, A");

            case 0xE0: return format("SET  4, B");
            case 0xE1: return format("SET  4, C");
            case 0xE2: return format("SET  4, D");
            case 0xE3: return format("SET  4, E");
            case 0xE4: return format("SET  4, H");
            case 0xE5: return format("SET  4, L");
            case 0xE6: return format("SET  4, (HL)");
            case 0xE7: return format("SET  4, A");

            case 0xE8: return format("SET  5, B");
            case 0xE9: return format("SET  5, C");
            case 0xEA: return format("SET  5, D");
            case 0xEB: return format("SET  5, E");
            case 0xEC: return format("SET  5, H");
            case 0xED: return format("SET  5, L");
            case 0xEE: return format("SET  5, (HL)");
            case 0xEF: return format("SET  5, A");

            case 0xF0: return format("SET  6, B");
            case 0xF1: return format("SET  6, C");
            case 0xF2: return format("SET  6, D");
            case 0xF3: return format("SET  6, E");
            case 0xF4: return format("SET  6, H");
            case 0xF5: return format("SET  6, L");
            case 0xF6: return format("SET  6, (HL)");
            case 0xF7: return format("SET  6, A");

            case 0xF8: return format("SET  7, B");
            case 0xF9: return format("SET  7, C");
            case 0xFA: return format("SET  7, D");
            case 0xFB: return format("SET  7, E");
            case 0xFC: return format("SET  7, H");
            case 0xFD: return format("SET  7, L");
            case 0xFE: return format("SET  7, (HL)");
            case 0xFF: return format("SET  7, A");

            default:
                return format("???? 0xCB $%02X", opcode);
        }
    }
}