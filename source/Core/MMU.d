module Core.MMU;

import std.stdio;
import std.string;

import Core.Timer;
import Core.Cart;
import Core.CPU;
import Core.LCD;
import Core.Joypad;
import Core.IGameboyDevice;
import Core.BootROM;
import Core.Gameboy;
import Core.APU;
import Core.Serial;


public enum IO : ushort {
    JOYPAD = 0xFF00,
    
    SERIAL_DATA    = 0xFF01,
    SERIAL_CONTROL = 0xFF02,
    
    TIMER_DIV     = 0xFF04,
    TIMER_COUNTER = 0xFF05,
    TIMER_MODULO  = 0xFF06,
    TIMER_CONTROL = 0xFF07,

    INT_FLAGS     = 0xFF0F,
    INT_ENABLED   = 0xFFFF,
    
    SND10 = 0xFF10,
    SND11 = 0xFF11,
    SND12 = 0xFF12,
    SND13 = 0xFF13,
    SND14 = 0xFF14,

    SND21 = 0xFF16,
    SND22 = 0xFF17,
    SND23 = 0xFF18,
    SND24 = 0xFF19,

    SND30 = 0xFF1A,
    SND31 = 0xFF1B,
    SND32 = 0xFF1C,
    SND33 = 0xFF1D,
    SND34 = 0xFF1E,

    SND41 = 0xFF20,
    SND42 = 0xFF21,
    SND43 = 0xFF22,
    SND44 = 0xFF23,
    
    SND50 = 0xFF24,
    SND51 = 0xFF25,
    SND52 = 0xFF26,

    SND_WAVE_START = 0xFF30,
    SND_WAVE_END = 0xFF3F,

    LCD_CONTROL = 0xFF40,
    LCD_STATUS  = 0xFF41,

    SCROLL_Y = 0xFF42,
    SCROLL_X = 0xFF43,
    
    SCANLINE     = 0xFF44,
    SCANLINE_CMP = 0xFF45,

    PAL_BG   = 0xFF47,
    PAL_OBJ0 = 0xFF48,
    PAL_OBJ1 = 0xFF49,

    BOOT = 0xFF50,
    
    WINDOW_Y = 0xFF4A,
    WINDOW_X = 0xFF4B,

    DMA_CONTROL = 0xFF46,
}

public enum Bus : ubyte {
    MAIN,
    RAM,
    VRAM,
    INTERNAL,
}

public final class MMU : IGameboyDevice {
    private Timer _timer;
    private Cart _cart;
    private CPU _cpu;
    private LCD _lcd;
    private Joypad _joypad;
    private Serial _serial;
    private APU _apu;
    private BootROM _bootrom;

    private ubyte[0x2000] _ram;
    private ubyte[0x7F] _hram;
    
    private bool _isBootROMEnabled;

    public void attach(Gameboy gameboy) {
        _timer = gameboy.timer;
        _cart = gameboy.cart;
        _cpu = gameboy.cpu;
        _lcd = gameboy.lcd;
        _joypad = gameboy.joypad;
        _serial = gameboy.serial;
        _apu = gameboy.apu;
        _bootrom = gameboy.bootrom;
    }

    public void reset() {
        _ram[] = 0;
        _hram[] = 0;
        _isBootROMEnabled = true;
    }

    public void cycle() {
    }

    public void write8(immutable ushort address, immutable ubyte data) {
        switch (address & 0xF000) {

            // Cart ROM area, used for MBC control.
            case 0x0000:
            case 0x1000:
            case 0x2000:
            case 0x3000:
            case 0x4000:
            case 0x5000:
            case 0x6000:
            case 0x7000:
                _cart.writeROM(address, data);
                break;

            // VRAM.
            case 0x8000:
            case 0x9000:
                _lcd.writeVRAM(address, data);
                break;
            
            // Cart RAM banks.
            case 0xA000:
            case 0xB000:
                _cart.writeRAM(address, data);
                break;
               
            // RAM banks 0 and 1.
            case 0xC000:
            case 0xD000:
                _ram[address - 0xC000] = data;
                break;

            // RAM bank 0 echo.
            case 0xE000:
                _ram[address - 0xE000] = data;
                break;

            case 0xF000:

                // RAM echo, up to OAM.
                if (address < 0xFE00) {
                    _ram[address - 0xE000] = data;

                // Object attributes.
                } else if (address >= 0xFE00 && address <= 0xFE9F) {
                    _lcd.writeOAM(address, data);

                // IO registers.
                } else if ((address >= 0xFF00 && address <= 0xFF7F) || address == 0xFFFF) {
                    writeIO(address, data);

                // High RAM area.
                } else if (address >= 0xFF80 && address <= 0xFFFE) {
                    _hram[address - 0xFF80] = data;

                }

                break;

            default:
                throw new Exception(format("Unhandled write at address 0x%04X.", address));
        }
    }

    public ubyte read8(immutable ushort address) {
        if (_isBootROMEnabled && address < _bootrom.size) {
            return _bootrom.read8(address);
        }

        switch (address & 0xF000) {
            
            // Cart banks.
            case 0x0000:
            case 0x1000:
            case 0x2000:
            case 0x3000:
            case 0x4000:
            case 0x5000:
            case 0x6000:
            case 0x7000:
                return _cart.readROM(address);

            // VRAM banks.
            case 0x8000:
            case 0x9000:
                return _lcd.readVRAM(address);

            // Cart RAM banks.
            case 0xA000:
            case 0xB000:
                return _cart.readRAM(address);

            // RAM banks 0 and 1.
            case 0xC000:
            case 0xD000:
                return _ram[address - 0xC000];

            // RAM bank 0 echo.
            case 0xE000:
                return _ram[address - 0xE000];

            case 0xF000:

                // RAM echo, up to OAM.
                if (address < 0xFE00) {
                    return _ram[address - 0xE000];

                // Object attributes.
                } else if (address >= 0xFE00 && address <= 0xFE9F) {
                    return _lcd.readOAM(address);

                // IO registers.
                } else if ((address >= 0xFF00 && address <= 0xFF7F) || address == 0xFFFF) {
                    return readIO(address);

                // High RAM area.
                } else if (address >= 0xFF80 && address <= 0xFFFE) {
                    return _hram[address - 0xFF80];

                }
                
                return 0x00;

            default:
                throw new Exception(format("Unhandled read at address 0x%04X.", address));
        }
    }

    pragma(inline, true)
    public ushort read16(immutable ushort address) {
        return read8(address) | (read8(cast(ushort)(address + 1)) << 8);
    }

    //pragma(inline, true)
    private ubyte readIO(immutable ushort address) {
        switch (address) {

            // Joypad.
            case IO.JOYPAD:
                return _joypad.status;

            // LCD control.
            case IO.LCD_CONTROL:
                return _lcd.control;
            case IO.LCD_STATUS:
                return _lcd.status;
            case IO.SCROLL_Y:
                return _lcd.bgY;
            case IO.SCROLL_X:
                return _lcd.bgX;
            case IO.SCANLINE_CMP:
                return _lcd.scanlineCmp;
            case IO.SCANLINE:
                return _lcd.scanline;
            case IO.WINDOW_Y:
                return _lcd.windowY;
            case IO.WINDOW_X:
                return _lcd.windowX;
            case IO.PAL_BG:
                return _lcd.palBG;
            case IO.PAL_OBJ0:
                return _lcd.palSprite0;
            case IO.PAL_OBJ1:
                return _lcd.palSprite1;
            
            // DMA.
            case IO.DMA_CONTROL:
                return _cpu.dmaAddress;

            // Audio.
            case IO.SND10:
            ..
            case IO.SND52:
                return _apu.readIO(address);

            case IO.SND_WAVE_START:
            ..
            case IO.SND_WAVE_END:
                return _apu.readWave(address);

            // Serial.
            case IO.SERIAL_DATA:
                return _serial.data;
            case IO.SERIAL_CONTROL:
                return _serial.control;

            // Timers.
            case IO.TIMER_DIV:
                return _timer.divider;
            case IO.TIMER_COUNTER:
                return _timer.counter;
            case IO.TIMER_MODULO:
                return _timer.modulo;
            case IO.TIMER_CONTROL:
                return _timer.control;

            // CPU interrupt flags.
            case IO.INT_ENABLED:
                return _cpu.interruptsEnabled;
            case IO.INT_FLAGS:
                return _cpu.interruptFlags;

            // Unmapped IO.
            default:
                return 0xFF;
        }
    }

    //pragma(inline, true)
    private void writeIO(immutable ushort address, immutable ubyte data) {
        switch (address) {

            // Joypad.
            case IO.JOYPAD:
                _joypad.status = data;
                break;

            // LCD control.
            case IO.LCD_CONTROL:
                _lcd.control = data;
                break;
            case IO.LCD_STATUS:
                _lcd.status = data;
                break;
            case IO.SCROLL_Y:
                _lcd.bgY = data;
                break;
            case IO.SCROLL_X:
                _lcd.bgX = data;
                break;
            case IO.SCANLINE_CMP:
                _lcd.scanlineCmp = data;
                break;
            case IO.WINDOW_Y:
                _lcd.windowY = data;
                break;
            case IO.WINDOW_X:
                _lcd.windowX = data;
                break;
            case IO.PAL_BG:
                _lcd.palBG = data;
                break;
            case IO.PAL_OBJ0:
                _lcd.palSprite0 = data;
                break;
            case IO.PAL_OBJ1:
                _lcd.palSprite1 = data;
                break;

            // DMA.
            case IO.DMA_CONTROL:
                _cpu.dmaAddress = data;
                break;

            // Sound IO.
            case IO.SND10:
            ..
            case IO.SND52:
                _apu.writeIO(address, data);
                break;

            case IO.SND_WAVE_START:
                ..
            case IO.SND_WAVE_END:
                _apu.writeWave(address, data);
                break;

            // Serial.
            case IO.SERIAL_DATA:
                _serial.data = data;
                break;
            case IO.SERIAL_CONTROL:
                _serial.control = data;
                break;

            // Disble boot ROM.
            case IO.BOOT:
                _isBootROMEnabled = false;
                break;

            // Timer.
            case IO.TIMER_DIV:
                _timer.divider = 0;
                break;
            case IO.TIMER_COUNTER:
                _timer.counter = data;
                break;
            case IO.TIMER_MODULO:
                _timer.modulo = data;
                break;
            case IO.TIMER_CONTROL:
                _timer.control = data;
                break;

            // CPU interrupt flags.
            case IO.INT_ENABLED:
                _cpu.interruptsEnabled = data;
                break;
            case IO.INT_FLAGS:
                _cpu.interruptFlags = data;
                break;

            default:
                break;
        }
    }

    public Bus busForAddress(immutable ushort address) {
        if (address < 0x8000) {
            return Bus.MAIN;
        }
        if (address < 0xA000) {
            return Bus.VRAM;
        }
        if (address < 0xC000) {
            return Bus.MAIN;
        }
        if (address < 0xFE00) {
            //return GB_is_cgb(gb)? GB_BUS_RAM : GB_BUS_MAIN;
            return Bus.MAIN;
        }

        return Bus.INTERNAL;
    }
}

// Echo RAM mirrors C000-DDFF at E000-FDFF.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");

    gameboy.mmu.write8(0xFDFF, 0x77);
    assert(gameboy.mmu.read8(0xDDFF) == 0x77);

    gameboy.mmu.write8(0xD123, 0x55);
    assert(gameboy.mmu.read8(0xF123) == 0x55);
}

// Unmapped IO reads as $FF and ignores writes.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    foreach (ushort address; [0xFF03, 0xFF08, 0xFF15, 0xFF27, 0xFF4C, 0xFF7F]) {
        gameboy.mmu.write8(address, 0x00);
        assert(gameboy.mmu.read8(address) == 0xFF);
    }
}

// IO registers read back what was written, with unused bits reading as 1.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    immutable ubyte[3][] cases = [
        // Address low byte, written, read.
        [0x07, 0x00, 0xF8],
        [0xFF, 0xE0, 0xE0],
        [0x10, 0x00, 0x80],
        [0x11, 0xC5, 0xFF],
        [0x12, 0xF3, 0xF3],
        [0x13, 0x12, 0xFF],
        [0x14, 0x40, 0xFF],
        [0x16, 0x80, 0xBF],
        [0x1A, 0x00, 0x7F],
        [0x1C, 0x00, 0x9F],
        [0x20, 0x00, 0xFF],
        [0x21, 0x5A, 0x5A],
        [0x23, 0x00, 0xBF],
        [0x24, 0x77, 0x77],
        [0x25, 0xF3, 0xF3],
        [0x26, 0x80, 0xF0],
    ];
    foreach (immutable ubyte[3] c; cases) {
        immutable ushort address = cast(ushort)(0xFF00 | c[0]);
        gameboy.mmu.write8(address, c[1]);
        assert(gameboy.mmu.read8(address) == c[2]);
    }
}
