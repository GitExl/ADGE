module Core.LCD;

import std.stdio;
import std.algorithm;
import std.conv;

import Core.CPU;
import Core.MMU;
import Core.IGameboyDevice;
import Core.Gameboy;


private enum Mode : ubyte {
    HBLANK = 0,
    VBLANK = 1,
    OAM    = 2,
    DATA   = 3,
}

private enum ControlFlag : ubyte {
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

private enum TileFlag : ubyte {
    NONE         = 0x00,
    TRANSPARENCY = 0x01,
    BEHIND       = 0x02,
    FLIP_X       = 0x04,
    FLIP_Y       = 0x08,
}

private enum SpriteFlag : ubyte {
    PRIORITY = 0x80,
    FLIP_Y   = 0x40,
    FLIP_X   = 0x20,
    PALETTE  = 0x10,
}

private align(1) struct Sprite {
    ubyte y;
    ubyte x;
    ubyte tileIndex;
    SpriteFlag flags;
}

alias ushort[4] Palette;

public alias void delegate() VBlankCallback;

private immutable ushort ADDR_TILEMAP_1 = 0x9800;
private immutable ushort ADDR_TILEMAP_2 = 0x9C00;

private immutable ushort ADDR_TILEGFX_1 = 0x8800;
private immutable ushort ADDR_TILEGFX_2 = 0x8000;

private immutable ushort ADDR_VRAM_BASE = 0x8000;
private immutable ushort ADDR_OAM_BASE  = 0xFE00;

private immutable ushort BUFFER_FLAG_OPAQUE = 0x8000;

private immutable ubyte DISPLAY_WIDTH  = 160;
private immutable ubyte DISPLAY_HEIGHT = 144;

private immutable uint CYCLES_MODE_OAM = 80;
private immutable uint CYCLES_MODE_DATA = 172;
private immutable uint CYCLES_MODE_HBLANK = 204;
private immutable uint CYCLES_MODE_VBLANK_LINE = 456;

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
    private bool _interruptLatch;

    private ubyte _bgX;
    private ubyte _bgY;
    private ubyte _windowX;
    private ubyte _windowY;

    private ubyte _scanline;
    private ubyte _scanlineCmp;

    private ubyte _palByteBG;
    private ubyte _palByteSprite0;
    private ubyte _palByteSprite1;

    private Palette _paletteBG;
    private Palette _paletteSprite0;
    private Palette _paletteSprite1;

    private Mode _mode;
    private int _modeCycles;

    private bool _vblankTriggered;
    private VBlankCallback _vblankCallback;

    private Sprite[10] _spriteQueue;
    private int _spriteQueueSize;
    private Sprite[40] _spriteList;
    
    private ubyte[0x2000] _vram;
    private ubyte[0xA0] _oam;
    private ushort[DISPLAY_WIDTH * DISPLAY_HEIGHT] _buffer;    

    public void attach(Gameboy gameboy) {
        _gameboy = gameboy;
        _cpu = gameboy.cpu;
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

        _interruptLatch = false;

        _palByteBG = 0;
        _palByteSprite0 = 0;
        _palByteSprite1 = 0;

        setPalette(_paletteBG, 0);
        setPalette(_paletteSprite0, 0);
        setPalette(_paletteSprite1, 0);

        _mode = Mode.OAM;
        _modeCycles = CYCLES_MODE_OAM;
        
        _vram[] = 0;
        _oam[] = 0;
        _buffer[] = 0;
    }

    public void cycle() {
        _vblankTriggered = false;

        /*// The PPU does not advance while in STOP mode on the DMG 
        if (gb->stopped && !GB_is_cgb(gb)) {
            gb->cycles_in_stop_mode += cycles;
            if (gb->cycles_in_stop_mode >= LCDC_PERIOD) {
                gb->cycles_in_stop_mode -= LCDC_PERIOD;
                display_vblank(gb);
            }
            return;
        }*/

        if (!_modeCycles) {
            if (_enabled) {
                if (_mode == Mode.OAM) {
                    setMode(Mode.DATA, CYCLES_MODE_DATA);

                } else if (_mode == Mode.DATA) {
                    setMode(Mode.HBLANK, CYCLES_MODE_HBLANK);

                } else if (_mode == Mode.HBLANK) {
                    setScanline(cast(ubyte)(_scanline + 1));
                    if (_scanline == 144) {
                        setMode(Mode.VBLANK, CYCLES_MODE_VBLANK_LINE);
                    } else {
                        setMode(Mode.OAM, CYCLES_MODE_OAM);
                    }

                } else if (_mode == Mode.VBLANK) {
                    if (_scanline == 153) {
                        vblank();
                        setScanline(0);
                        setMode(Mode.OAM, CYCLES_MODE_OAM);
                    } else {
                        setScanline(cast(ubyte)(_scanline + 1));
                        _modeCycles = CYCLES_MODE_VBLANK_LINE;
                    }
                }
            
            } else {
                if (_scanline == 153) {
                    vblank();
                    setScanline(0);
                    _modeCycles = CYCLES_MODE_VBLANK_LINE;
                } else {
                    setScanline(cast(ubyte)(_scanline + 1));
                    _modeCycles = CYCLES_MODE_VBLANK_LINE;
                }
            }
        }
        _modeCycles -= 4;            
    }

    private void setScanline(immutable ubyte scanline) {
        _scanline = scanline;

        if (_scanline == 144) {
            /* Entering VBlank state triggers the OAM interrupt */
            //gb->io_registers[GB_IO_STAT] &= ~3;
            //gb->io_registers[GB_IO_STAT] |= 1;

//            _cpu.triggerInterrupt(InterruptFlag.VBLANK);
        }

        if (_enabled && _interruptScanline && _scanline == _scanlineCmp) {
            _cpu.triggerInterrupt(InterruptFlag.LCD_STATUS);
        }
    }

    private void setMode(immutable Mode mode, immutable int cycles) {
        _mode = mode;
        _modeCycles = cycles;

        if (_mode == Mode.OAM) {
            prepareScanline(_scanline);
        } else if (_mode == Mode.DATA) {
            renderScanline(_scanline);
        }

        //testInterrupts();

        // Trigger mode interrupts.
        if (_enabled) {
            if (_mode == Mode.HBLANK && _interruptHBlank) {
                _cpu.triggerInterrupt(InterruptFlag.LCD_STATUS);
            } else if (_mode == Mode.VBLANK) {
                _cpu.triggerInterrupt(InterruptFlag.VBLANK);
                if (_interruptVBlank) {
                    _cpu.triggerInterrupt(InterruptFlag.LCD_STATUS);
                }
            } else if (_mode == Mode.OAM && _interruptOAM) {
                _cpu.triggerInterrupt(InterruptFlag.LCD_STATUS);
            }
        }
    }

    private void testInterrupts() {

        // Interrupts are only triggered when going from none to one.
        const bool newInterruptLatch =
            (_interruptScanline && _scanline == _scanlineCmp) ||
            (_interruptHBlank && _mode == Mode.HBLANK) ||
            (_interruptVBlank && _mode == Mode.VBLANK) ||
            (_interruptOAM && _mode == Mode.OAM);
        if (newInterruptLatch && !_interruptLatch) {
            _cpu.triggerInterrupt(InterruptFlag.LCD_STATUS);
        }

        _interruptLatch = newInterruptLatch;
    }

    private void prepareScanline(immutable int scanLine) {

        // Clear scanline.
        _buffer[scanLine * DISPLAY_WIDTH..scanLine * DISPLAY_WIDTH + DISPLAY_WIDTH] = 0;

        // Build list of sprites sorted by X.
        for (int i = 0; i < 40; i++) {
            Sprite* sprite = cast(Sprite*)&_oam[i * 4];
            _spriteList[i] = *sprite;
        }
        if (_gameboy.mode != GameboyMode.COLOR) {
            _spriteList[].sort!("a.x > b.x", SwapStrategy.stable);
        }

        // Store all sprites that are visible and on the current scanline.
        _spriteQueueSize = 0;
        immutable int spriteHeight = _largeSprites ? 16 : 8;
        foreach (ref Sprite sprite; _spriteList) {
            
            // Determine if the sprite is visible at all.
            if (sprite.y == 0 || sprite.y >= DISPLAY_HEIGHT + 16) {
                continue;
            }

            if (scanLine >= (sprite.y - 16) && scanLine < (sprite.y - 16) + spriteHeight) {
                _spriteQueue[_spriteQueueSize] = sprite;
                _spriteQueueSize++;
                if (_spriteQueueSize == _spriteQueue.length) {
                    break;
                }
            }
        }
    }

    private void renderScanline(immutable int scanLine) {
        if (_enableBG) {
            renderTilemap(scanLine, _bgTilemap, _bgWindowTileGFX, _bgX, _bgY, _paletteBG);
        }
        if (_enableWindow) {
            immutable int windowX = -cast(int)((_windowX < 7) ? 0 : _windowX - 7);
            immutable int windowY = -cast(int)_windowY;
            renderTilemap(scanLine, _windowTilemap, _bgWindowTileGFX, windowX, windowY, _paletteBG);
        }
        if (_enableSprites) {
            renderSprites(scanLine);
        }
    }

    private void renderSprites(immutable int scanLine) {
        immutable int spriteHeight = _largeSprites ? 16 : 8;

        for (int index = 0; index < _spriteQueueSize; index++) {
            const Sprite sprite = _spriteQueue[index];

            if (sprite.x == 0 || sprite.x >= DISPLAY_WIDTH + 8) {
                continue;
            }

            // Offset sprite coordinates.
            immutable int x = sprite.x - 8;
            immutable int y = sprite.y - 16;

            // Apply flags for rendering the tile.
            TileFlag flags = TileFlag.TRANSPARENCY;
            if (sprite.flags & SpriteFlag.FLIP_X) {
                flags |= TileFlag.FLIP_X;
            }
            if (sprite.flags & SpriteFlag.FLIP_Y) {
                flags |= TileFlag.FLIP_Y;
            }
            if (sprite.flags & SpriteFlag.PRIORITY) {
                flags |= TileFlag.BEHIND;
            }

            Palette palette = (sprite.flags & SpriteFlag.PALETTE) ? _paletteSprite1 : _paletteSprite0;

            // Large sprites are 8x16, so render the scanline of either the top or bottom tile.
            if (_largeSprites) {
                immutable int py = (scanLine - y) % 16;
                if (sprite.flags & SpriteFlag.FLIP_Y) {
                    if (py < 8) {
                        renderTile(ADDR_TILEGFX_2, sprite.tileIndex | 0x01, palette, x, scanLine, 0, py, flags);
                    } else {
                        renderTile(ADDR_TILEGFX_2, sprite.tileIndex & 0xFE, palette, x, scanLine, 0, py - 8, flags);
                    }
                } else {
                    if (py < 8) {
                        renderTile(ADDR_TILEGFX_2, sprite.tileIndex & 0xFE, palette, x, scanLine, 0, py, flags);
                    } else {
                        renderTile(ADDR_TILEGFX_2, sprite.tileIndex | 0x01, palette, x, scanLine, 0, py - 8, flags);
                    }
                }

            // Render a scanline of a regular tile.
            } else {
                immutable int py = (scanLine - y) % 8;
                renderTile(ADDR_TILEGFX_2, sprite.tileIndex, palette, x, scanLine, 0, py, flags);
            }
        }
    }

    private void renderTilemap(immutable int scanLine, immutable ushort tilesAddr, immutable ushort gfxAddr, immutable int scrollX, immutable int scrollY, ref Palette palette) {
        immutable int ry = scanLine;

        if (scrollY + ry < 0) {
            return;
        }
        
        int tileIndex;
        ubyte color;

        int rx = 0;
        while (rx < DISPLAY_WIDTH) {
            if (scrollX + rx < 0) {
                rx += 8;
                continue;
            }

            immutable int tileX = ((rx + scrollX) / 8) % 32;
            immutable int tileY = ((ry + scrollY) / 8) % 32;
            immutable ushort tileAddr = cast(ushort)(tilesAddr - ADDR_VRAM_BASE + (tileY * 32) + tileX);
            if (gfxAddr == ADDR_TILEGFX_2) {
                tileIndex = _vram[tileAddr];
            } else {
                tileIndex = cast(byte)_vram[tileAddr] + 128;
            }

            immutable int pixelX = (rx + scrollX) % 8;
            immutable int pixelY = (ry + scrollY) % 8;
            renderTile(gfxAddr, tileIndex, palette, rx, ry, pixelX, pixelY, TileFlag.NONE);

            rx += 8 - pixelX;
        }
    }

    private void renderTile(immutable ushort baseAddr, immutable int index, ref Palette palette,
                            int x, int y, int px, int py, immutable TileFlag flags) {
        if (x < 0) {
            px += -x;
            x = 0;
        }
        if (y < 0) {
            py += -y;
            y = 0;
        }

        ushort gfxAddr = cast(ushort)(baseAddr - ADDR_VRAM_BASE + index * 16);
        if (flags & TileFlag.FLIP_Y) {
             gfxAddr += (7 - py) * 2;
        } else {
            gfxAddr += py * 2;
        }

        immutable uint endAddr = (y + 1) * DISPLAY_WIDTH;
        uint destAddr = y * DISPLAY_WIDTH + x;

        ubyte color;
        bool transparent;
        bool behind;
        for (int xx = px; xx < 8; xx++) {
            if (flags & TileFlag.FLIP_X) {
                color = cast(ubyte)(1 << xx);
            } else {
                color = cast(ubyte)(1 << (7 - xx));
            }
            color = ((_vram[gfxAddr] & color) ? 1 : 0) |
                    ((_vram[gfxAddr + 1] & color) ? 2 : 0);

            transparent = ((flags & TileFlag.TRANSPARENCY) && !color);
            behind = (flags & TileFlag.BEHIND) && (_buffer[destAddr] & BUFFER_FLAG_OPAQUE);
            if (!transparent && !behind) {
                _buffer[destAddr] = palette[color];
                if (color) {
                    _buffer[destAddr] |= BUFFER_FLAG_OPAQUE;
                }
            }
            
            destAddr++;
            if (destAddr >= endAddr) {
                break;
            }
        }
    }

    public void vblank() {
        _vblankTriggered = true;
        _vblankCallback();
    }

    public void writeVRAM(immutable ushort address, immutable ubyte data) {
        if (_enabled && _mode == Mode.DATA) {
            return;
        }

        _vram[address - ADDR_VRAM_BASE] = data;
    }

    public ubyte readVRAM(immutable ushort address) {
        if (_enabled && _mode == Mode.DATA) {
            return 0xFF;
        }

        return _vram[address - ADDR_VRAM_BASE];
    }

    public void writeOAM(immutable ushort address, immutable ubyte data) {
        if (_enabled && (_mode == Mode.DATA || _mode == Mode.OAM)) {
            return;
        }

        _oam[address - ADDR_OAM_BASE] = data;
    }

    public ubyte readOAM(immutable ushort address) {
        if (_enabled && (_mode == Mode.DATA || _mode == Mode.OAM)) {
            return 0xFF;
        }

        return _oam[address - ADDR_OAM_BASE];
    }

    public ubyte readOAMDirect(immutable ushort address) {
        return _oam[address - ADDR_OAM_BASE];
    }

    private void setPalette(ref Palette pal, immutable ubyte value) {
        for (ubyte i = 0; i < 4; i++) {
            pal[i] = (value >> (i * 2)) & 0x03;
        }
    }

    private void lcdDisable() {
        _buffer[] = 0;
        if (_mode != Mode.VBLANK) {
            writeln("Warning: turned LCD off outside of VBlank.");
            _buffer[_scanline * DISPLAY_WIDTH.._scanline * DISPLAY_WIDTH + DISPLAY_WIDTH] = 0x03;
        }
    }

    private void lcdEnable() {
        _scanline = 0;
        _mode = Mode.OAM;
        _modeCycles = CYCLES_MODE_OAM;
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
        if (_scanline == _scanlineCmp) value |= StatusFlag.SCANLINE_CMP;
        if (_enabled) {
            value |= _mode;
        }

        return value;
    }

    @property
    public void status(immutable ubyte value) {
        _interruptScanline = cast(bool)(value & StatusFlag.INT_SCANLINE);
        _interruptOAM      = cast(bool)(value & StatusFlag.INT_OAM);
        _interruptVBlank   = cast(bool)(value & StatusFlag.INT_VBLANK);
        _interruptHBlank   = cast(bool)(value & StatusFlag.INT_HBLANK);
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
        setPalette(_paletteBG, value);
    }

    @property
    public ubyte palSprite0() {
        return _palByteSprite0;
    }

    @property
    public void palSprite0(immutable ubyte value) {
        _palByteSprite0 = value;
        setPalette(_paletteSprite0, value);
    }

    @property
    public ubyte palSprite1() {
        return _palByteSprite1;
    }

    @property
    public void palSprite1(immutable ubyte value) {
        _palByteSprite1 = value;
        setPalette(_paletteSprite1, value);
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