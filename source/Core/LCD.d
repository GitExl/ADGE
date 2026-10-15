module Core.LCD;

import std.stdio;
import std.algorithm;
import std.conv;

import Core.CPU;
import Core.MMU;
import Core.IGameboyDevice;
import Core.Gameboy;
import Core.PixelFIFO;


private enum Mode : ubyte {
    HBLANK = 0,
    VBLANK = 1,
    OAM    = 2,
    DATA   = 3,
}

// Reads and writes are locked during different M-cycles.
private enum Access : ubyte {
    READ,
    WRITE,
}

package enum ControlFlag : ubyte {
    ENABLE_BG          = 0x01,
    ENABLE_SPRITES     = 0x02,
    LARGE_SPRITES      = 0x04,
    BG_TILEMAP         = 0x08,
    BG_WINDOW_TILEGFX  = 0x10,
    ENABLE_WINDOW      = 0x20,
    WINDOW_TILEMAP     = 0x40,
    ENABLE             = 0x80,
}

private enum StatusFlag : ubyte {
    MODE_MASK    = 0x03,
    SCANLINE_CMP = 0x04,
    INT_HBLANK   = 0x08,
    INT_VBLANK   = 0x10,
    INT_OAM      = 0x20,
    INT_SCANLINE = 0x40,
}

public alias void delegate() VBlankCallback;

private immutable ushort ADDR_TILEMAP_1 = 0x9800;
private immutable ushort ADDR_TILEMAP_2 = 0x9C00;

private immutable ushort ADDR_TILEGFX_1 = 0x8800;
private immutable ushort ADDR_TILEGFX_2 = 0x8000;

private immutable ushort ADDR_VRAM_BASE = 0x8000;
package immutable ushort ADDR_OAM_BASE  = 0xFE00;

private immutable ubyte DISPLAY_WIDTH  = 160;
private immutable ubyte DISPLAY_HEIGHT = 144;

// A line starts with one M-cycle in which LY has changed, but STAT still reads mode 0 with no LY match.
// It is counted as part of the OAM mode, since OAM is already locked.
private immutable uint CYCLES_LINE_START = 4;
private immutable uint CYCLES_MODE_OAM = CYCLES_LINE_START + 80;
private immutable uint CYCLES_MODE_DATA = 172;
private immutable uint CYCLES_MODE_HBLANK = 204 - CYCLES_LINE_START;

// After vblank, the OAM scan of line 0 ends an M-cycle early, and its hblank lasts an M-cycle longer.
// Measured with mealybug-tearoom-tests, which compensate for it on line 0.
private immutable uint CYCLES_LINE_0_EARLY = 4;
private immutable uint CYCLES_MODE_VBLANK_LINE = 456;

// The pixel FIFO decides how long mode 3 lasts. STAT reads mode 0 a few dots before it ends,
// while the mode 0 interrupt waits for the end.
private immutable int CYCLES_HBLANK_STATUS_EARLY = 3;

public final class LCD : IGameboyDevice {
    private Gameboy _gameboy;
    private CPU _cpu;

    private bool _enabled;
    private bool _enableSprites;
    private bool _enableWindow;
    private bool _enableBG;

    private ushort _windowTilemap;
    private ushort _bgWindowTileGFX;
    private ushort _bgTilemap;
    
    private bool _largeSprites;
    
    private bool _interruptScanline;
    private bool _interruptOAM;
    private bool _interruptVBlank;
    private bool _interruptHBlank;
    private bool _statLine;

    private ubyte _bgX;
    private ubyte _bgY;
    private ubyte _windowX;
    private ubyte _windowY;

    private ubyte _scanline;
    private ubyte _scanlineCmp;

    // The LY=LYC comparison only runs while the LCD is on. Its result is kept while it is off.
    private bool _lycMatch;

    private ubyte _palByteBG;
    private ubyte _palByteSprite0;
    private ubyte _palByteSprite1;

    private Mode _mode;
    private int _modeCycles;
    private int _oamLength;
    private int _dataLength;
    private int _hblankLength;

    // Line 0 after enabling the LCD has no OAM scan. STAT reads mode 0 and OAM is accessible instead.
    private bool _firstLine;

    private bool _vblankTriggered;
    private VBlankCallback _vblankCallback;

    private PixelFIFO _fifo;

    private ubyte[0x2000] _vram;
    private ubyte[0xA0] _oam;
    private ushort[DISPLAY_WIDTH * DISPLAY_HEIGHT] _buffer; 
    
    public void attach(Gameboy gameboy) {
        _gameboy = gameboy;
        _cpu = gameboy.cpu;
        _fifo = PixelFIFO(this);
    }

    public void reset() {
        control = 0;
        status = 0;

        _bgX = 0;
        _bgY = 0;
        _windowX = 0;
        _windowY = 0;

        _scanline = 0;
        _scanlineCmp = 0;

        _statLine = false;
        _lycMatch = false;

        _palByteBG = 0;
        _palByteSprite0 = 0;
        _palByteSprite1 = 0;

        _mode = Mode.OAM;
        _modeCycles = 0;
        _oamLength = CYCLES_MODE_OAM;
        _dataLength = CYCLES_MODE_DATA;
        _hblankLength = CYCLES_MODE_HBLANK;
        
        _vram[] = 0;
        _oam[] = 0;
        _buffer[] = 0;

        _fifo.startFrame();
    }

    public void cycle() {
        _vblankTriggered = false;

        _modeCycles += 4;
        switch (_mode) {
            case Mode.OAM:
                if (_modeCycles >= _oamLength) {
                    _modeCycles -= _oamLength;
                    _firstLine = false;
                    setMode(Mode.DATA);
                    _fifo.startLine(_scanline);
                }
                break;

            case Mode.DATA:
                if (drawPixels()) {
                    _modeCycles -= _dataLength;
                    _hblankLength = CYCLES_MODE_HBLANK + CYCLES_MODE_DATA + CYCLES_MODE_OAM - _oamLength - _dataLength;
                    setMode(Mode.HBLANK);
                }
                break;

            case Mode.HBLANK:
                if (_enabled) {
                    _fifo.advance(_dataLength + _modeCycles);
                }
                if (_modeCycles >= _hblankLength) {
                    _modeCycles -= _hblankLength;
                    if (_scanline == 143) {
                        setMode(Mode.VBLANK);
                        vblank();
                    } else {
                        setMode(Mode.OAM);
                    }                    
                    setScanline(cast(ubyte)(_scanline + 1));
                }
                break;

            case Mode.VBLANK:
                if (isVBlankStart()) {
                    _cpu.triggerInterrupt(InterruptFlag.VBLANK);
                }
                if (_modeCycles >= CYCLES_MODE_VBLANK_LINE) {
                    _modeCycles -= CYCLES_MODE_VBLANK_LINE;
                    
                    if (_scanline == 153) {
                        setMode(Mode.OAM);
                        setScanline(0);
                    } else {
                        setScanline(cast(ubyte)(_scanline + 1));
                    }
                }
                break;
            default:
                break;
        }

        if (_enabled) {
            _lycMatch = _scanline == _scanlineCmp && !isLineStart();
        }
        updateStatLine();
    }

    private void setScanline(immutable ubyte scanline) {
        _scanline = scanline;
        _oamLength = scanline == 0 ? CYCLES_MODE_OAM - CYCLES_LINE_0_EARLY : CYCLES_MODE_OAM;
    }

    // In the last M-cycle of the OAM scan, VRAM reads are already locked but OAM writes pass.
    private int oamScanEnd() {
        return _oamLength - 4;
    }

    private void setMode(immutable Mode mode) {
        _mode = mode;
    }

    private bool isVBlankStart() {
        return _enabled && _mode == Mode.VBLANK && _scanline == DISPLAY_HEIGHT && _modeCycles == CYCLES_LINE_START;
    }

    // All enabled STAT interrupt conditions share one line, and an interrupt is only requested when it rises.
    // So while one condition holds, another one starting does not request an interrupt.
    private void updateStatLine() {
        immutable Mode mode = _enabled ? statusMode() : Mode.HBLANK;
        immutable bool line =
            (_interruptScanline && _lycMatch) ||
            (_interruptHBlank && mode == Mode.HBLANK && !(_mode == Mode.HBLANK && _modeCycles < 0)) ||
            (_interruptVBlank && mode == Mode.VBLANK) ||

            // The mode 2 condition is also met for an M-cycle when vblank starts.
            (_interruptOAM && (mode == Mode.OAM || isVBlankStart()));

        if (line && !_statLine) {
            _cpu.triggerInterrupt(InterruptFlag.LCD_STATUS);
        }
        _statLine = line;
    }

    // Draws up to the current dot of mode 3. Returns true when STAT should switch to mode 0.
    // With the LCD off nothing is drawn, but the timing keeps running so frames still complete.
    private bool drawPixels() {
        if (!_enabled) {
            _dataLength = CYCLES_MODE_DATA;
            return _modeCycles + CYCLES_HBLANK_STATUS_EARLY >= _dataLength;
        }

        if (!_fifo.advance(_modeCycles)) {
            return false;
        }

        _dataLength = _fifo.length + CYCLES_HBLANK_STATUS_EARLY;
        return true;
    }

    public void vblank() {
        _vblankTriggered = true;
        _fifo.startFrame();
        _vblankCallback();
    }

    public void writeVRAM(immutable ushort address, immutable ubyte data) {
        if (isVRAMLocked(Access.WRITE)) {
            return;
        }

        _vram[address - ADDR_VRAM_BASE] = data;
    }

    // The pixel FIFO reads VRAM while it is locked to the CPU.
    package ubyte readVRAMDirect(immutable ushort address) {
        return _vram[address - ADDR_VRAM_BASE];
    }

    public ubyte readVRAM(immutable ushort address) {
        if (isVRAMLocked(Access.READ)) {
            return 0xFF;
        }

        return _vram[address - ADDR_VRAM_BASE];
    }

    public void writeOAM(immutable ushort address, immutable ubyte data) {
        if (isOAMLocked(Access.WRITE)) {
            return;
        }

        _oam[address - ADDR_OAM_BASE] = data;
    }

    public ubyte readOAM(immutable ushort address) {
        if (isOAMLocked(Access.READ)) {
            return 0xFF;
        }

        return _oam[address - ADDR_OAM_BASE];
    }

    private bool isOAMLocked(immutable Access access) {
        if (!_enabled || _firstLine) {
            return false;
        }
        if (_mode == Mode.DATA) {
            return true;
        }
        if (_mode != Mode.OAM) {
            return false;
        }
        if (access == Access.READ) {
            return true;
        }

        // Writes pass at the line start and in the last M-cycle of the OAM scan.
        return !isLineStart() && _modeCycles < oamScanEnd();
    }

    private bool isVRAMLocked(immutable Access access) {
        if (!_enabled) {
            return false;
        }
        if (_mode == Mode.DATA) {
            return true;
        }

        // Reads lock in the last M-cycle of the OAM scan already.
        return access == Access.READ && _mode == Mode.OAM && !_firstLine && _modeCycles >= oamScanEnd();
    }

    private bool isLineStart() {
        if (!_enabled || _firstLine || _modeCycles >= CYCLES_LINE_START) {
            return false;
        }
        return _mode == Mode.OAM || _mode == Mode.VBLANK;
    }

    private Mode statusMode() {
        if (_mode == Mode.OAM && _firstLine) {
            return Mode.HBLANK;
        }

        // The mode changes after LY. Lines 145 and up stay in vblank.
        if (isLineStart() && (_mode == Mode.OAM || _scanline == DISPLAY_HEIGHT)) {
            return Mode.HBLANK;
        }

        return _mode;
    }

    public ubyte readOAMDirect(immutable ushort address) {
        return _oam[address - ADDR_OAM_BASE];
    }

    // DMA bypasses the PPU's OAM lock.
    public void writeOAMDirect(immutable ushort address, immutable ubyte data) {
        _oam[address - ADDR_OAM_BASE] = data;
    }

    private void lcdDisable() {
        _buffer[] = 0;
        if (_mode != Mode.VBLANK) {
            writeln("Warning: turned LCD off outside of VBlank.");
            _buffer[_scanline * DISPLAY_WIDTH.._scanline * DISPLAY_WIDTH + DISPLAY_WIDTH] = 0x03;
        }
    }

    // The PPU starts late, so line 0 is one M-cycle short.
    private void lcdEnable() {
        _scanline = 0;
        _oamLength = CYCLES_MODE_OAM;
        _fifo.startFrame();
        _mode = Mode.OAM;
        _modeCycles = CYCLES_LINE_START;
        _firstLine = true;
    }

    @property
    public ubyte control() {
        ubyte value;
        
        if (_enabled)       value |= ControlFlag.ENABLE;
        if (_enableSprites) value |= ControlFlag.ENABLE_SPRITES;
        if (_enableWindow)  value |= ControlFlag.ENABLE_WINDOW;
        if (_enableBG)      value |= ControlFlag.ENABLE_BG;
        if (_largeSprites)  value |= ControlFlag.LARGE_SPRITES;

        if (_windowTilemap   == ADDR_TILEMAP_2) value |= ControlFlag.WINDOW_TILEMAP;
        if (_bgTilemap       == ADDR_TILEMAP_2) value |= ControlFlag.BG_TILEMAP;
        if (_bgWindowTileGFX == ADDR_TILEGFX_2) value |= ControlFlag.BG_WINDOW_TILEGFX;
        
        return value;
    }

    @property
    public void control(immutable ubyte value) {
        
        if (_enabled && !(value & ControlFlag.ENABLE)) {
            lcdDisable();
        } else if (!_enabled && (value & ControlFlag.ENABLE)) {
            lcdEnable();
        }

        _enabled       = cast(bool)(value & ControlFlag.ENABLE);
        _enableSprites = cast(bool)(value & ControlFlag.ENABLE_SPRITES);
        _enableWindow  = cast(bool)(value & ControlFlag.ENABLE_WINDOW);
        _enableBG      = cast(bool)(value & ControlFlag.ENABLE_BG);
        _largeSprites  = cast(bool)(value & ControlFlag.LARGE_SPRITES);
        
        _windowTilemap   = (value & ControlFlag.WINDOW_TILEMAP)    ? ADDR_TILEMAP_2 : ADDR_TILEMAP_1;
        _bgTilemap       = (value & ControlFlag.BG_TILEMAP)        ? ADDR_TILEMAP_2 : ADDR_TILEMAP_1;
        _bgWindowTileGFX = (value & ControlFlag.BG_WINDOW_TILEGFX) ? ADDR_TILEGFX_2 : ADDR_TILEGFX_1;
    }

    @property
    public ubyte status() {
        ubyte value = 0x80;

        if (_interruptScanline)        value |= StatusFlag.INT_SCANLINE;
        if (_interruptOAM)             value |= StatusFlag.INT_OAM;
        if (_interruptVBlank)          value |= StatusFlag.INT_VBLANK;
        if (_interruptHBlank)          value |= StatusFlag.INT_HBLANK;
        if (_enabled) {
            value |= statusMode();
        }
        if (_lycMatch) value |= StatusFlag.SCANLINE_CMP;

        return value;
    }

    @property
    public void status(immutable ubyte value) {
        _interruptScanline = cast(bool)(value & StatusFlag.INT_SCANLINE);
        _interruptOAM      = cast(bool)(value & StatusFlag.INT_OAM);
        _interruptVBlank   = cast(bool)(value & StatusFlag.INT_VBLANK);
        _interruptHBlank   = cast(bool)(value & StatusFlag.INT_HBLANK);
        updateStatLine();
    }

    @property
    public ubyte bgX() {
        return _bgX;
    }

    @property
    public void bgX(immutable ubyte value) {
        _bgX = value;
    }

    @property
    public ubyte bgY() {
        return _bgY;
    }

    @property
    public void bgY(immutable ubyte value) {
        _bgY = value;
    }

    @property
    public ubyte windowX() {
        return _windowX;
    }

    @property
    public void windowX(immutable ubyte value) {
        _windowX = value;
    }

    @property
    public ubyte windowY() {
        return _windowY;
    }

    @property
    public void windowY(immutable ubyte value) {
        _windowY = value;
    }

    @property
    public ubyte scanline() {
        if (_enabled) {
            return _scanline;
        }
        
        return 0;
    }
    
    @property
    public ubyte scanlineCmp() {
        return _scanlineCmp;
    }

    @property
    public void scanlineCmp(immutable ubyte value) {
        _scanlineCmp = value;
    }

    @property
    public ubyte palBG() {
        return _palByteBG;
    }

    @property
    public void palBG(immutable ubyte value) {
        _palByteBG = value;
    }

    @property
    public ubyte palSprite0() {
        return _palByteSprite0;
    }

    @property
    public void palSprite0(immutable ubyte value) {
        _palByteSprite0 = value;
    }

    @property
    public ubyte palSprite1() {
        return _palByteSprite1;
    }

    @property
    public void palSprite1(immutable ubyte value) {
        _palByteSprite1 = value;
    }

    @property
    public ushort[] buffer() {
        return _buffer;
    }

    @property
    public ushort addressTileGFX() {
        return _bgWindowTileGFX;
    }

    @property
    public ushort addressTilemapBG() {
        return _bgTilemap;
    }

    @property
    public ushort addressTilemapWindow() {
        return _windowTilemap;
    }

    @property
    public VBlankCallback vblankCallback() {
        return _vblankCallback;
    }

    @property
    void vblankCallback(VBlankCallback callback) {
        _vblankCallback = callback;
    }

    @property
    bool vblankTriggered() {
        return _vblankTriggered;
    }
}

// Advances the LCD by a number of M-cycles.
private void tickLCD(Gameboy gameboy, immutable uint cycles) {
    foreach (i; 0 .. cycles) {
        gameboy.lcd.cycle();
    }
}

// Line 0 after enabling the LCD has no OAM scan and is one M-cycle short.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.control = ControlFlag.ENABLE;
    gameboy.lcd.writeOAM(0xFE00, 0x81);
    assert(gameboy.lcd.readOAM(0xFE00) == 0x81);

    tickLCD(gameboy, 19);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.HBLANK);
    tickLCD(gameboy, 1);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.DATA);
    tickLCD(gameboy, 43);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.HBLANK);
    tickLCD(gameboy, 49);
    assert(gameboy.lcd.scanline == 0);
    tickLCD(gameboy, 1);
    assert(gameboy.lcd.scanline == 1);
}

// In the first M-cycle of a line, LY has changed, but STAT reads mode 0 with no LY match while OAM is locked.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.scanlineCmp = 1;
    gameboy.lcd.control = ControlFlag.ENABLE;
    tickLCD(gameboy, 113);

    assert(gameboy.lcd.scanline == 1);
    assert(gameboy.lcd.status == 0x80);
    assert(gameboy.lcd.readOAM(0xFE00) == 0xFF);

    tickLCD(gameboy, 1);
    assert(gameboy.lcd.status == (0x80 | StatusFlag.SCANLINE_CMP | Mode.OAM));
    tickLCD(gameboy, 20);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.DATA);
    tickLCD(gameboy, 93);
    assert(gameboy.lcd.scanline == 2);
}

// The mode 2 STAT interrupt fires when STAT shows mode 2, one M-cycle after the line starts.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.status = StatusFlag.INT_OAM;
    gameboy.lcd.control = ControlFlag.ENABLE;
    tickLCD(gameboy, 113);
    assert(!(gameboy.cpu.interruptFlags & InterruptFlag.LCD_STATUS));
    tickLCD(gameboy, 1);
    assert(gameboy.cpu.interruptFlags & InterruptFlag.LCD_STATUS);
}

// VRAM locks one M-cycle before STAT shows mode 3.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.control = ControlFlag.ENABLE;
    tickLCD(gameboy, 113 + 19);
    assert(gameboy.lcd.readVRAM(0x8000) == 0x00);
    tickLCD(gameboy, 1);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.OAM);
    assert(gameboy.lcd.readVRAM(0x8000) == 0xFF);
}

// Vblank starts one M-cycle after LY reaches 144, also requesting a STAT interrupt if mode 2 interrupts are enabled.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.vblankCallback = delegate void() {};
    gameboy.lcd.status = StatusFlag.INT_OAM;
    gameboy.lcd.control = ControlFlag.ENABLE;
    tickLCD(gameboy, 113 + 143 * 114);
    gameboy.cpu.interruptFlags = 0;

    assert(gameboy.lcd.scanline == 144);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.HBLANK);
    assert(!(gameboy.cpu.interruptFlags & InterruptFlag.VBLANK));
    tickLCD(gameboy, 1);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.VBLANK);
    assert(gameboy.cpu.interruptFlags & InterruptFlag.VBLANK);
    assert(gameboy.cpu.interruptFlags & InterruptFlag.LCD_STATUS);
}

// Writes to OAM pass in the first and last M-cycle of the OAM scan, writes to VRAM until mode 3 starts.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.control = ControlFlag.ENABLE;

    immutable ubyte[3][] cases = [
        // M-cycles to advance, OAM written, VRAM written.
        [113, 1, 1],
        [1, 0, 1],
        [18, 0, 1],
        [1, 1, 1],
        [1, 0, 0],
    ];
    foreach (immutable ubyte[3] c; cases) {
        tickLCD(gameboy, c[0]);
        gameboy.lcd._oam[0] = 0;
        gameboy.lcd._vram[0] = 0;
        gameboy.lcd.writeOAM(0xFE00, 0x81);
        gameboy.lcd.writeVRAM(0x8000, 0x81);
        assert((gameboy.lcd._oam[0] == 0x81) == cast(bool)c[1]);
        assert((gameboy.lcd._vram[0] == 0x81) == cast(bool)c[2]);
    }
}

// Enabling a STAT interrupt for the current mode requests it right away.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.vblankCallback = delegate void() {};
    gameboy.lcd.control = ControlFlag.ENABLE;
    tickLCD(gameboy, 113 + 143 * 114 + 2);
    gameboy.cpu.interruptFlags = 0;

    gameboy.lcd.status = StatusFlag.INT_VBLANK;
    assert(gameboy.cpu.interruptFlags & InterruptFlag.LCD_STATUS);
}

// STAT interrupts are requested when any enabled condition starts, while none was active.
// Going from mode 0 straight into mode 2 with both enabled requests nothing.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.status = StatusFlag.INT_HBLANK | StatusFlag.INT_OAM;
    gameboy.lcd.control = ControlFlag.ENABLE;
    tickLCD(gameboy, 100);
    assert(gameboy.cpu.interruptFlags & InterruptFlag.LCD_STATUS);
    gameboy.cpu.interruptFlags = 0;

    tickLCD(gameboy, 14);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.OAM);
    assert(!(gameboy.cpu.interruptFlags & InterruptFlag.LCD_STATUS));
}

// The LY=LYC flag only updates while the LCD is on.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.control = ControlFlag.ENABLE;
    tickLCD(gameboy, 1);
    assert(gameboy.lcd.status & StatusFlag.SCANLINE_CMP);

    gameboy.lcd.control = 0;
    gameboy.lcd.scanlineCmp = 1;
    tickLCD(gameboy, 1);
    assert(gameboy.lcd.status & StatusFlag.SCANLINE_CMP);

    gameboy.lcd.control = ControlFlag.ENABLE;
    tickLCD(gameboy, 1);
    assert(!(gameboy.lcd.status & StatusFlag.SCANLINE_CMP));
}

// Fine scrolling lengthens mode 3 by SCX mod 8 dots. STAT reads mode 0 3 dots before mode 3 ends,
// but the mode 0 interrupt waits for its end.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.bgX = 1;
    gameboy.lcd.status = StatusFlag.INT_HBLANK;
    gameboy.lcd.control = ControlFlag.ENABLE;
    tickLCD(gameboy, 176);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.DATA);
    gameboy.cpu.interruptFlags = 0;

    tickLCD(gameboy, 1);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.HBLANK);
    assert(!(gameboy.cpu.interruptFlags & InterruptFlag.LCD_STATUS));
    tickLCD(gameboy, 1);
    assert(gameboy.cpu.interruptFlags & InterruptFlag.LCD_STATUS);
}

// An object on the line lengthens mode 3 by 6 dots, plus up to 5 while the background tile it starts in is fetched.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd._oam[0] = 17;
    gameboy.lcd._oam[1] = 0;
    gameboy.lcd.status = StatusFlag.INT_HBLANK;
    gameboy.lcd.control = ControlFlag.ENABLE | ControlFlag.ENABLE_SPRITES;
    tickLCD(gameboy, 178);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.DATA);
    gameboy.cpu.interruptFlags = 0;

    tickLCD(gameboy, 1);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.HBLANK);
    assert(!(gameboy.cpu.interruptFlags & InterruptFlag.LCD_STATUS));
    tickLCD(gameboy, 1);
    assert(gameboy.cpu.interruptFlags & InterruptFlag.LCD_STATUS);
}

private void renderLine(Gameboy gameboy, immutable int scanLine) {
    gameboy.lcd._fifo.startLine(scanLine);
    gameboy.lcd._fifo.advance(int.max);
}

private ubyte shadeAt(Gameboy gameboy, immutable int x, immutable int y) {
    return gameboy.lcd.buffer[y * DISPLAY_WIDTH + x] & 0x03;
}

private void setObject(Gameboy gameboy, immutable int index, immutable ubyte x, immutable SpriteFlag flags) {
    gameboy.lcd._oam[index * 4 .. index * 4 + 4] = [16, x, 0, flags];
}

// Tile 0 is solid color 3.
private Gameboy newRenderTest(immutable ubyte control) {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd._vram[0 .. 16] = 0xFF;
    gameboy.lcd.control = control;
    gameboy.lcd.palSprite0 = 0xFF;
    gameboy.lcd.palSprite1 = 0x55;
    return gameboy;
}

// The first 10 objects in OAM order on a line are drawn, whatever their X.
unittest {
    Gameboy gameboy = newRenderTest(ControlFlag.ENABLE | ControlFlag.ENABLE_SPRITES);
    foreach (int i; 0 .. 11) {
        setObject(gameboy, i, cast(ubyte)(8 + i * 8), cast(SpriteFlag)0);
    }
    setObject(gameboy, 10, 100, cast(SpriteFlag)0);
    setObject(gameboy, 0, 120, cast(SpriteFlag)0);

    renderLine(gameboy, 0);
    assert(shadeAt(gameboy, 112, 0) == 3);
    assert(shadeAt(gameboy, 92, 0) == 0);
}

// Overlapping objects: lower X wins, then lower OAM index.
unittest {
    Gameboy gameboy = newRenderTest(ControlFlag.ENABLE | ControlFlag.ENABLE_SPRITES);
    setObject(gameboy, 0, 12, SpriteFlag.PALETTE);
    setObject(gameboy, 1, 8, cast(SpriteFlag)0);
    setObject(gameboy, 2, 40, SpriteFlag.PALETTE);
    setObject(gameboy, 3, 40, cast(SpriteFlag)0);

    renderLine(gameboy, 0);
    assert(shadeAt(gameboy, 4, 0) == 3);
    assert(shadeAt(gameboy, 32, 0) == 1);
}

// An object behind the background still hides lower priority objects.
unittest {
    Gameboy gameboy = newRenderTest(ControlFlag.ENABLE | ControlFlag.ENABLE_SPRITES | ControlFlag.ENABLE_BG | ControlFlag.BG_WINDOW_TILEGFX);
    gameboy.lcd.palBG = 0x80;
    setObject(gameboy, 0, 8, SpriteFlag.PRIORITY);
    setObject(gameboy, 1, 8, SpriteFlag.PALETTE);

    renderLine(gameboy, 0);
    assert(shadeAt(gameboy, 0, 0) == 2);
}

// The window keeps its own line counter, which only advances on lines it is drawn on.
unittest {
    Gameboy gameboy = newRenderTest(ControlFlag.ENABLE | ControlFlag.ENABLE_BG | ControlFlag.ENABLE_WINDOW | ControlFlag.BG_TILEMAP | ControlFlag.BG_WINDOW_TILEGFX);
    gameboy.lcd._vram[0 .. 16] = 0x00;
    gameboy.lcd._vram[32 + 2 .. 32 + 4] = 0xFF;
    gameboy.lcd._vram[ADDR_TILEMAP_1 - ADDR_VRAM_BASE .. ADDR_TILEMAP_1 - ADDR_VRAM_BASE + 32] = 2;
    gameboy.lcd.palBG = 0xFC;
    gameboy.lcd.windowX = 7;

    renderLine(gameboy, 0);
    assert(shadeAt(gameboy, 0, 0) == 0);

    gameboy.lcd.control = gameboy.lcd.control & ~ControlFlag.ENABLE_WINDOW;
    renderLine(gameboy, 1);
    gameboy.lcd.control = gameboy.lcd.control | ControlFlag.ENABLE_WINDOW;
    renderLine(gameboy, 2);
    assert(shadeAt(gameboy, 0, 2) == 3);
}

// On DMG, disabling the background also disables the window.
unittest {
    Gameboy gameboy = newRenderTest(ControlFlag.ENABLE | ControlFlag.ENABLE_WINDOW | ControlFlag.BG_WINDOW_TILEGFX);
    gameboy.lcd.palBG = 0xFF;
    gameboy.lcd.windowX = 7;

    renderLine(gameboy, 0);
    assert(shadeAt(gameboy, 0, 0) == 0);
}

// Ticks into mode 3 of line 1, then returns the M-cycles until STAT reads mode 0.
private int measureMode3(Gameboy gameboy) {
    while (gameboy.lcd.scanline != 1 || (gameboy.lcd.status & StatusFlag.MODE_MASK) != Mode.DATA) {
        gameboy.lcd.cycle();
    }

    int cycles;
    while ((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.DATA) {
        gameboy.lcd.cycle();
        cycles++;
    }
    return cycles;
}

// Mode 3 length per https://gbdev.io/pandocs/Rendering.html#mode-3-length, without the window.
// Objects are fetched from left to right, so the first object in a tile is the leftmost one, not the first in OAM.
private int expectedMode3Dots(const ubyte[] oam, immutable ubyte scx, immutable int scanLine, immutable int height) {
    int[] objectX;
    for (int i = 0; i < 40 && objectX.length < 10; i++) {
        immutable int y = oam[i * 4] - 16;
        if (scanLine >= y && scanLine < y + height) {
            objectX ~= oam[i * 4 + 1];
        }
    }
    objectX.sort();

    immutable int fineScroll = scx & 7;
    int length = 172 + fineScroll;
    bool[22] tileFetched;
    foreach (int x; objectX) {
        if (x >= 168) {
            continue;
        }

        length += 6;
        immutable int tile = (x + fineScroll) / 8;
        if (tileFetched[tile]) {
            continue;
        }

        tileFetched[tile] = true;
        length += max(0, 5 - (x + fineScroll) % 8);
    }

    return length;
}

// Mode 3 lasts as long as fine scrolling and object fetches take. STAT reads mode 0 3 dots early.
unittest {
    import std.random;

    auto random = Random(1);
    foreach (int run; 0 .. 200) {
        Gameboy gameboy = new Gameboy("dmg", "dmg");
        gameboy.lcd.vblankCallback = delegate void() {};

        immutable bool large = uniform(0, 2, random) == 1;
        immutable ubyte scx = cast(ubyte)uniform(0, 256, random);
        immutable int objects = uniform(0, 14, random);
        foreach (int i; 0 .. objects) {
            immutable int index = uniform(0, 40, random);
            gameboy.lcd._oam[index * 4] = cast(ubyte)uniform(8, 20, random);
            gameboy.lcd._oam[index * 4 + 1] = cast(ubyte)uniform(0, 176, random);
        }

        gameboy.lcd.bgX = scx;
        gameboy.lcd.control = cast(ubyte)(ControlFlag.ENABLE | ControlFlag.ENABLE_BG | ControlFlag.ENABLE_SPRITES | (large ? ControlFlag.LARGE_SPRITES : 0));

        immutable int dots = expectedMode3Dots(gameboy.lcd._oam, scx, 1, large ? 16 : 8);
        assert(measureMode3(gameboy) == (dots - 3 + 3) / 4);
    }
}

// Starting the window costs 6 dots.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.windowX = 7;
    gameboy.lcd.control = ControlFlag.ENABLE | ControlFlag.ENABLE_BG | ControlFlag.ENABLE_WINDOW;

    assert(measureMode3(gameboy) == (172 + 6 - 3 + 3) / 4);
}

// Pixels are drawn during mode 3, so a palette write halfway through a line only affects the pixels after it.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd._vram[0 .. 16] = 0xFF;
    gameboy.lcd.palBG = 0xFF;
    gameboy.lcd.control = ControlFlag.ENABLE | ControlFlag.ENABLE_BG | ControlFlag.BG_WINDOW_TILEGFX;

    while (gameboy.lcd.scanline != 1 || (gameboy.lcd.status & StatusFlag.MODE_MASK) != Mode.DATA) {
        gameboy.lcd.cycle();
    }
    tickLCD(gameboy, 20);
    gameboy.lcd.palBG = 0x00;
    tickLCD(gameboy, 30);

    assert(shadeAt(gameboy, 0, 1) == 3);
    assert(shadeAt(gameboy, 159, 1) == 0);
}

// Nothing is drawn while the LCD is off.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.vblankCallback = delegate void() {};
    gameboy.lcd._vram[0 .. 16] = 0xFF;
    gameboy.lcd.palBG = 0xFF;
    gameboy.lcd.control = ControlFlag.ENABLE_BG | ControlFlag.BG_WINDOW_TILEGFX;

    tickLCD(gameboy, 17556);
    assert(gameboy.lcd.buffer.all!(pixel => pixel == 0));
}

// After vblank, line 0 starts mode 3 one M-cycle earlier than other lines.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.vblankCallback = delegate void() {};
    gameboy.lcd.control = ControlFlag.ENABLE;
    gameboy.lcd.status = StatusFlag.INT_OAM;
    while (gameboy.lcd.scanline != 153) {
        gameboy.lcd.cycle();
    }
    while (gameboy.lcd.scanline != 0) {
        gameboy.lcd.cycle();
    }
    gameboy.cpu.interruptFlags = 0;

    tickLCD(gameboy, 1);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.OAM);
    assert(gameboy.cpu.interruptFlags & InterruptFlag.LCD_STATUS);

    tickLCD(gameboy, 18);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.OAM);
    tickLCD(gameboy, 1);
    assert((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.DATA);
}

// On DMG, a palette written during mode 3 reads as the old and new value ORed together for one dot.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd._vram[0 .. 16] = [0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00];
    gameboy.lcd.palBG = 0b0100;
    gameboy.lcd.control = ControlFlag.ENABLE | ControlFlag.ENABLE_BG | ControlFlag.BG_WINDOW_TILEGFX;

    while (gameboy.lcd.scanline != 1 || (gameboy.lcd.status & StatusFlag.MODE_MASK) != Mode.DATA) {
        gameboy.lcd.cycle();
    }
    tickLCD(gameboy, 20);
    gameboy.lcd.palBG = 0b1000;
    tickLCD(gameboy, 40);

    int blended;
    foreach (int x; 0 .. 160) {
        if (shadeAt(gameboy, x, 1) == 3) {
            blended++;
        }
    }
    assert(blended == 1);
    assert(shadeAt(gameboy, 0, 1) == 1);
    assert(shadeAt(gameboy, 159, 1) == 2);
}

private void tickToLine1Mode3(Gameboy gameboy) {
    while (gameboy.lcd.scanline != 1 || (gameboy.lcd.status & StatusFlag.MODE_MASK) != Mode.DATA) {
        gameboy.lcd.cycle();
    }
}

// The background is color 1. The window starts at line 1 and x 0. Its first line is color 0, the lines below color 3.
private Gameboy newWindowTest() {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.vblankCallback = delegate void() {};
    gameboy.lcd._vram[0 .. 16] = [0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00];
    gameboy.lcd._vram[32 + 2 .. 32 + 16] = 0xFF;
    gameboy.lcd._vram[ADDR_TILEMAP_2 - ADDR_VRAM_BASE .. ADDR_TILEMAP_2 - ADDR_VRAM_BASE + 32] = 2;
    gameboy.lcd.palBG = 0xE4;
    gameboy.lcd.windowX = 7;
    gameboy.lcd.windowY = 1;
    gameboy.lcd.control = ControlFlag.ENABLE | ControlFlag.ENABLE_BG | ControlFlag.ENABLE_WINDOW | ControlFlag.WINDOW_TILEMAP | ControlFlag.BG_WINDOW_TILEGFX;
    return gameboy;
}

// Disabling the window during mode 3 switches back to the background at the next tile.
unittest {
    Gameboy gameboy = newWindowTest();
    tickToLine1Mode3(gameboy);
    tickLCD(gameboy, 10);
    gameboy.lcd.control = gameboy.lcd.control & ~ControlFlag.ENABLE_WINDOW;
    tickLCD(gameboy, 40);

    assert(shadeAt(gameboy, 0, 1) == 0);
    assert(shadeAt(gameboy, 159, 1) == 1);
}

// Enabling the window again before WX is reached draws its next line from there.
unittest {
    Gameboy gameboy = newWindowTest();
    tickToLine1Mode3(gameboy);
    tickLCD(gameboy, 10);
    gameboy.lcd.control = gameboy.lcd.control & ~ControlFlag.ENABLE_WINDOW;
    tickLCD(gameboy, 2);
    gameboy.lcd.windowX = 120;
    gameboy.lcd.control = gameboy.lcd.control | ControlFlag.ENABLE_WINDOW;
    tickLCD(gameboy, 40);

    assert(shadeAt(gameboy, 80, 1) == 1);
    assert(shadeAt(gameboy, 159, 1) == 3);
}

// Moving WX so the drawn window matches it again just as a window tile is pushed inserts a blank pixel.
unittest {
    Gameboy gameboy = newWindowTest();
    gameboy.lcd._vram[32 .. 34] = 0xFF;
    tickToLine1Mode3(gameboy);
    tickLCD(gameboy, 4);
    gameboy.lcd.windowX = 15;
    tickLCD(gameboy, 46);

    assert(shadeAt(gameboy, 7, 1) == 3);
    assert(shadeAt(gameboy, 8, 1) == 0);
    assert(shadeAt(gameboy, 9, 1) == 3);
}

// Disabling objects while an object waits for its background tile cancels the fetch. Mode 3 then only lasts
// the wait longer, instead of the wait and the fetch.
unittest {
    Gameboy gameboy = new Gameboy("dmg", "dmg");
    gameboy.lcd.vblankCallback = delegate void() {};
    gameboy.lcd._oam[0 .. 4] = [17, 16, 0, 0];
    gameboy.lcd.control = ControlFlag.ENABLE | ControlFlag.ENABLE_BG | ControlFlag.ENABLE_SPRITES;

    tickToLine1Mode3(gameboy);
    tickLCD(gameboy, 6);
    gameboy.lcd.control = ControlFlag.ENABLE | ControlFlag.ENABLE_BG;

    int cycles = 6;
    while ((gameboy.lcd.status & StatusFlag.MODE_MASK) == Mode.DATA) {
        gameboy.lcd.cycle();
        cycles++;
    }
    assert(cycles == (172 + 5 - 3 + 3) / 4);
}
