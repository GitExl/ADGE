module Core.PixelFIFO;

import std.algorithm;

import Core.LCD;


// Draws a scanline one dot at a time during mode 3, like the hardware's pixel FIFO. Register writes take effect
// on the pixels drawn or fetched after them, and the time the fetches take decides how long mode 3 lasts.
//
//   background/window fetcher --> background FIFO --+
//                                                   +--> output delay --> palettes --> screen
//   object fetch -------------->  object FIFO -----+
//
// The fetcher reads a tile number, then the low and high tile data bytes, 2 dots each, and pushes the 8 pixels
// once the background FIFO is empty. Each dot shifts one pixel out of both FIFOs, unless an object fetch stalls
// the shifter. The first 8 pixels shifted are a dummy tile, followed by those discarded for fine scrolling.
// Shifted pixels get their palette a few dots later, so the last ones reach the screen after mode 3 has ended.
// See https://gbdev.io/pandocs/pixel_fifo.html
//
// Each part of the pipeline sees register writes at a slightly different time. To allow that, the FIFO runs a
// few dots behind the mode timing that STAT shows, and records the registers for every dot. A part then reads
// the registers as they were a fixed number of dots ahead of the dot it is on.

package enum SpriteFlag : ubyte {
    PRIORITY = 0x80,
    FLIP_Y   = 0x40,
    FLIP_X   = 0x20,
    PALETTE  = 0x10,
}

private enum FetchStep : ubyte {
    TILE,
    DATA_LOW,
    DATA_HIGH,
    PUSH,
}

private enum PaletteIndex {
    BACKGROUND,
    OBJECT0,
    OBJECT1,
}

// The registers the FIFO reads, as they were on one dot.
private struct Registers {
    ubyte control;
    ubyte scrollX;
    ubyte scrollY;
    ubyte windowX;
    ubyte windowY;
    ubyte[3] palettes;
}

private struct ObjectPixel {
    ubyte color;
    bool palette1;
    bool behindBackground;
}

// A shifted pixel waits a few dots before its palette is looked up and it reaches the screen.
private struct ShiftedPixel {
    ubyte background;
    ObjectPixel object;
    int x;
    int dot;
}

private struct LineObject {
    ubyte x;
    ubyte oamIndex;
    bool fetched;
}

private immutable int SCREEN_WIDTH = 160;
private immutable int TILE_SIZE = 8;
private immutable int TILE_BYTES = 16;
private immutable int TILEMAP_SIZE = 32;
private immutable int FETCH_STEP_DOTS = 2;

// The shifter starts one dot into mode 3. Mode 3 ends when the last pixel is shifted out, which STAT shows
// 3 dots before the documented 172 dots without fine scroll or objects.
private immutable int SHIFT_START_DELAY = 1;

private immutable int OAM_OBJECTS = 40;
private immutable int OAM_ENTRY_SIZE = 4;
private immutable int MAX_LINE_OBJECTS = 10;
private immutable int OBJECT_Y_OFFSET = 16;

// An object fetch takes 6 dots. The first object in a background tile first waits up to 5 dots for that tile's
// fetch to finish. See https://gbdev.io/pandocs/Rendering.html#mode-3-length
private immutable int OBJECT_FETCH_DOTS = 6;
private immutable int OBJECT_WAIT_MAX = 5;
private immutable int OBJECT_LOW_DOT = 4;
private immutable int NO_OBJECT = -1;

private immutable int WINDOW_X_OFFSET = 7;
private immutable int WINDOW_X_MAX = 166;

private immutable ushort TILE_DATA_UNSIGNED = 0x8000;
private immutable ushort TILE_DATA_SIGNED = 0x9000;
private immutable ushort TILEMAP_LOW = 0x9800;
private immutable ushort TILEMAP_HIGH = 0x9C00;

private immutable int REGISTER_HISTORY = 16;
private immutable int OUTPUT_QUEUE = 16;

// Each part of the FIFO reads the registers as they were a number of dots ahead of the dot it is on, which sets
// when it sees a register write. Object fetches and the window enable bit see a write 2 dots before the
// background fetcher, WX and the pixel mixer do. The FIFO runs the largest lead behind the mode timing that STAT
// shows. Measured with mealybug-tearoom-tests.
private immutable int BACKGROUND_LEAD = 4;
private immutable int OBJECT_LEAD = 6;
private immutable int WINDOW_ENABLE_LEAD = 6;
private immutable int MAX_LEAD = 6;

// The first tile fetch starts one dot into mode 3.
private immutable int FETCH_START_DELAY = 1;

// Dots between shifting a pixel out and reading LCDC for it, and looking up its palette.
private immutable int CONTROL_DELAY = 1;
private immutable int OUTPUT_DELAY = 2;

public struct PixelFIFO {
    private LCD _lcd;

    private int _scanline;
    private int _fineScroll;
    private int _dots;
    private int _shiftDelay;
    private bool _done;
    private bool _ended;
    private int _length;

    // A copy of the FIFO runs ahead to find when mode 3 ends. It must not draw.
    private bool _predicting;

    private Registers[REGISTER_HISTORY] _registers;
    private int _recorded;

    // Pixels shifted out so far, including the dummy tile and the ones discarded for fine scrolling.
    private int _position;

    private ShiftedPixel[OUTPUT_QUEUE] _output;
    private int _outputCount;

    // Room for a tile, plus pixels pushed in front of it.
    private ubyte[TILE_SIZE * 2] _backgroundPixels;
    private int _backgroundHead;
    private int _backgroundCount;
    private ObjectPixel[TILE_SIZE] _objectPixels;

    private FetchStep _fetchStep;
    private int _fetchDots;
    private int _fetchX;
    private ubyte _fetchTile;
    private ubyte _fetchLow;
    private ubyte _fetchHigh;

    private LineObject[MAX_LINE_OBJECTS] _objects;
    private int _objectCount;
    private int _objectWait;
    private int _objectFetch;
    private int _fetchingObject;
    private ubyte _objectLow;
    private bool _tileWaited;

    // The window shows from the line where LY equals WY, and keeps its own line counter, which only advances
    // on lines it is drawn on.
    private bool _windowYMatched;
    private bool _fetchingWindow;
    private int _windowLine;
    private int _windowLines;
    private int _windowStart;

    public this(LCD lcd) {
        _lcd = lcd;
    }

    public void startFrame() {
        _windowYMatched = false;
        _windowLine = 0;
        _windowLines = 0;
    }

    public void startLine(immutable int scanline) {
        _scanline = scanline;
        _dots = 0;
        _shiftDelay = SHIFT_START_DELAY;
        _done = false;
        _ended = false;
        _predicting = false;
        _position = 0;
        _outputCount = 0;

        _registers[] = currentRegisters();
        _recorded = 0;
        _fineScroll = _registers[0].scrollX % TILE_SIZE;

        _backgroundPixels[] = 0;
        _backgroundHead = TILE_SIZE;
        _backgroundCount = TILE_SIZE;
        _objectPixels[] = ObjectPixel();

        _fetchStep = FetchStep.TILE;
        _fetchDots = -FETCH_START_DELAY;
        _fetchX = 0;

        _objectWait = 0;
        _objectFetch = 0;
        _fetchingObject = NO_OBJECT;
        _tileWaited = false;

        _fetchingWindow = false;
        if (scanline == _registers[0].windowY) {
            _windowYMatched = true;
        }

        selectObjects();
    }

    // Draws until mode 3 has lasted the given number of dots. Returns true once STAT shows that mode 3 has
    // ended. The FIFO itself is behind, so it still draws the last pixels in the dots after that.
    public bool advance(immutable int dots) {
        record(dots);
        run(dots - MAX_LEAD);
        if (_ended) {
            return true;
        }

        immutable int lastPosition = SCREEN_WIDTH - 1 + TILE_SIZE + _fineScroll;
        if (lastPosition - _position >= MAX_LEAD) {
            return false;
        }

        PixelFIFO ahead = this;
        ahead._predicting = true;
        ahead.run(dots);
        if (!ahead._ended) {
            return false;
        }

        _length = ahead._length;
        return true;
    }

    // The number of dots it took to shift out all pixels, as STAT shows it.
    @property
    public int length() {
        return _length;
    }

    private Registers currentRegisters() {
        return Registers(_lcd.control, _lcd.bgX, _lcd.bgY, _lcd.windowX, _lcd.windowY,
            [_lcd.palBG, _lcd.palSprite0, _lcd.palSprite1]);
    }

    // Records the current registers for the dots up to the given one.
    private void record(immutable int dots) {
        immutable Registers current = currentRegisters();
        if (dots - _recorded >= REGISTER_HISTORY) {
            _registers[] = current;
        } else {
            foreach (int dot; _recorded + 1 .. dots + 1) {
                _registers[dot % REGISTER_HISTORY] = current;
            }
        }
        _recorded = max(_recorded, dots);
    }

    // The registers as a part of the FIFO that leads by the given number of dots sees them.
    private Registers registers(immutable int dot, immutable int lead) const {
        return _registers[min(dot + lead, _recorded) % REGISTER_HISTORY];
    }

    private void run(immutable int dots) {
        while (_dots < dots && !(_done && !_outputCount)) {
            step();
        }
    }

    // Objects are selected in OAM order, whatever their X.
    private void selectObjects() {
        immutable int height = objectHeight(_registers[0].control);
        _objectCount = 0;
        foreach (int i; 0 .. OAM_OBJECTS) {
            immutable ushort address = cast(ushort)(ADDR_OAM_BASE + i * OAM_ENTRY_SIZE);
            immutable int y = _lcd.readOAMDirect(address) - OBJECT_Y_OFFSET;
            if (_scanline < y || _scanline >= y + height) {
                continue;
            }

            _objects[_objectCount] = LineObject(_lcd.readOAMDirect(cast(ushort)(address + 1)), cast(ubyte)i, false);
            _objectCount++;
            if (_objectCount == MAX_LINE_OBJECTS) {
                break;
            }
        }
    }

    private void step() {
        _dots++;
        if (!_done) {
            startWindow();
            stepFetcher();
            stepShifter();
        }
        outputPixels();
    }

    private void outputPixels() {
        while (_outputCount && _output[0].dot + OUTPUT_DELAY <= _dots) {
            immutable ShiftedPixel pixel = _output[0];
            if (!_predicting) {
                _lcd.buffer[_scanline * SCREEN_WIDTH + pixel.x] = mixPixel(pixel);
            }

            foreach (int i; 1 .. _outputCount) {
                _output[i - 1] = _output[i];
            }
            _outputCount--;
        }
    }

    private void startWindow() {
        immutable ubyte control = registers(_dots, WINDOW_ENABLE_LEAD).control;
        if (!_windowYMatched || !(control & ControlFlag.ENABLE_WINDOW)) {
            return;
        }

        immutable int windowX = registers(_dots, BACKGROUND_LEAD).windowX;
        if (windowX > WINDOW_X_MAX || _position != windowX - WINDOW_X_OFFSET + TILE_SIZE + _fineScroll) {
            return;
        }

        // Matching a changed WX while the window is drawn pushes a blank pixel, if that happens just as the
        // fetcher pushes the next window tile.
        if (_fetchingWindow) {
            if (_position != _windowStart && _fetchStep == FetchStep.PUSH && !_backgroundCount) {
                _backgroundHead--;
                _backgroundPixels[_backgroundHead] = 0;
                _backgroundCount++;
            }
            return;
        }

        // Each time the window starts, including again on the same line, it draws its next line.

        _fetchingWindow = true;
        _windowStart = _position;
        _windowLine = _windowLines & 0xFF;
        _windowLines++;
        _backgroundCount = 0;
        _fetchStep = FetchStep.TILE;
        _fetchDots = 0;
        _fetchX = 0;
    }

    private void stepFetcher() {
        if (_fetchStep == FetchStep.PUSH) {
            if (_backgroundCount) {
                return;
            }

            pushTile();
            _fetchStep = FetchStep.TILE;
            return;
        }

        _fetchDots++;
        if (_fetchDots < FETCH_STEP_DOTS) {
            return;
        }

        _fetchDots = 0;
        final switch (_fetchStep) {
            case FetchStep.TILE:
                _fetchTile = readTileNumber();
                _fetchStep = FetchStep.DATA_LOW;
                break;
            case FetchStep.DATA_LOW:
                _fetchLow = readTileData(0);
                _fetchStep = FetchStep.DATA_HIGH;
                break;
            case FetchStep.DATA_HIGH:
                _fetchHigh = readTileData(1);
                _fetchStep = FetchStep.PUSH;
                break;
            case FetchStep.PUSH:
                break;
        }
    }

    private ubyte readTileNumber() {
        immutable Registers registers = registers(_dots, BACKGROUND_LEAD);

        // Disabling the window switches back to the background at the next tile.
        if (_fetchingWindow && !(registers.control & ControlFlag.ENABLE_WINDOW)) {
            _fetchingWindow = false;
        }

        ushort address;
        if (_fetchingWindow) {
            immutable ushort tilemap = (registers.control & ControlFlag.WINDOW_TILEMAP) ? TILEMAP_HIGH : TILEMAP_LOW;
            address = cast(ushort)(tilemap + (_windowLine / TILE_SIZE) * TILEMAP_SIZE + _fetchX % TILEMAP_SIZE);
        } else {

            // The low bits of SCX are latched when the first tile is fetched.
            if (!_fetchX) {
                _fineScroll = registers.scrollX % TILE_SIZE;
            }

            immutable ushort tilemap = (registers.control & ControlFlag.BG_TILEMAP) ? TILEMAP_HIGH : TILEMAP_LOW;
            immutable int y = (_scanline + registers.scrollY) & 0xFF;
            immutable int x = (registers.scrollX / TILE_SIZE + _fetchX) % TILEMAP_SIZE;
            address = cast(ushort)(tilemap + (y / TILE_SIZE) * TILEMAP_SIZE + x);
        }
        _fetchX++;

        return _lcd.readVRAMDirect(address);
    }

    private ubyte readTileData(immutable int plane) {
        immutable Registers registers = registers(_dots, BACKGROUND_LEAD);
        immutable int row = _fetchingWindow ? _windowLine % TILE_SIZE : ((_scanline + registers.scrollY) & 0xFF) % TILE_SIZE;

        ushort address;
        if (registers.control & ControlFlag.BG_WINDOW_TILEGFX) {
            address = cast(ushort)(TILE_DATA_UNSIGNED + _fetchTile * TILE_BYTES);
        } else {
            address = cast(ushort)(TILE_DATA_SIGNED + cast(byte)_fetchTile * TILE_BYTES);
        }

        return _lcd.readVRAMDirect(cast(ushort)(address + row * 2 + plane));
    }

    private void pushTile() {
        foreach (int i; 0 .. TILE_SIZE) {
            _backgroundPixels[TILE_SIZE + i] = tilePixel(_fetchLow, _fetchHigh, i);
        }
        _backgroundHead = TILE_SIZE;
        _backgroundCount = TILE_SIZE;
        _tileWaited = false;
    }

    private void stepShifter() {
        if (_fetchingObject != NO_OBJECT) {
            stepObjectFetch();
            return;
        }

        if (_shiftDelay) {
            _shiftDelay--;
            return;
        }

        if (!_backgroundCount) {
            return;
        }

        if (startObjectFetch()) {
            stepObjectFetch();
            return;
        }

        shiftPixel();
    }

    // Starts fetching the next object that begins at the pixel about to be shifted out.
    private bool startObjectFetch() {
        foreach (int i; 0 .. _objectCount) {
            if (_objects[i].fetched || _objects[i].x + _fineScroll != _position) {
                continue;
            }

            _objects[i].fetched = true;
            if (!objectsEnabled()) {
                continue;
            }

            immutable int shifted = max(0, TILE_SIZE - _backgroundCount);
            _objectWait = _tileWaited ? 0 : max(0, OBJECT_WAIT_MAX - shifted);
            _tileWaited = true;
            _fetchingObject = i;
            return true;
        }

        return false;
    }

    // Waits for the background fetch, then fetches the object. Disabling objects before the fetch itself
    // starts cancels it, and the pixel is shifted out right away.
    private void stepObjectFetch() {
        if (_objectWait) {
            _objectWait--;
            return;
        }

        if (!_objectFetch && !objectsEnabled()) {
            _fetchingObject = NO_OBJECT;
            shiftPixel();
            return;
        }

        _objectFetch++;
        if (_objectFetch == OBJECT_LOW_DOT) {
            _objectLow = readObjectData(_objects[_fetchingObject].oamIndex, 0);
        }
        if (_objectFetch < OBJECT_FETCH_DOTS) {
            return;
        }

        _objectFetch = 0;
        mergeObject(_objects[_fetchingObject].oamIndex);
        _fetchingObject = NO_OBJECT;
    }

    private bool objectsEnabled() const {
        return cast(bool)(registers(_dots, OBJECT_LEAD).control & ControlFlag.ENABLE_SPRITES);
    }

    private ubyte readObjectData(immutable int oamIndex, immutable int plane) {
        immutable ushort address = cast(ushort)(ADDR_OAM_BASE + oamIndex * OAM_ENTRY_SIZE);
        immutable int y = _lcd.readOAMDirect(address) - OBJECT_Y_OFFSET;
        immutable ubyte tile = _lcd.readOAMDirect(cast(ushort)(address + 2));
        immutable SpriteFlag flags = cast(SpriteFlag)_lcd.readOAMDirect(cast(ushort)(address + 3));

        immutable int height = objectHeight(registers(_dots, OBJECT_LEAD).control);
        int row = (_scanline - y) & (height - 1);
        if (flags & SpriteFlag.FLIP_Y) {
            row = height - 1 - row;
        }

        // 8x16 objects ignore bit 0 of the tile number, so the row runs on into the next tile.
        immutable int tileIndex = height == TILE_SIZE * 2 ? tile & 0xFE : tile;
        immutable ushort data = cast(ushort)(TILE_DATA_UNSIGNED + tileIndex * TILE_BYTES + row * 2);
        return _lcd.readVRAMDirect(cast(ushort)(data + plane));
    }

    // Earlier objects keep their pixels, so overlapping objects show by priority: lower X, then lower OAM index.
    private void mergeObject(immutable int oamIndex) {
        immutable ushort address = cast(ushort)(ADDR_OAM_BASE + oamIndex * OAM_ENTRY_SIZE);
        immutable SpriteFlag flags = cast(SpriteFlag)_lcd.readOAMDirect(cast(ushort)(address + 3));
        immutable ubyte high = readObjectData(oamIndex, 1);

        foreach (int i; 0 .. TILE_SIZE) {
            immutable ubyte color = tilePixel(_objectLow, high, (flags & SpriteFlag.FLIP_X) ? TILE_SIZE - 1 - i : i);
            if (!color || _objectPixels[i].color) {
                continue;
            }

            _objectPixels[i] = ObjectPixel(color, cast(bool)(flags & SpriteFlag.PALETTE), cast(bool)(flags & SpriteFlag.PRIORITY));
        }
    }

    private void shiftPixel() {
        immutable ubyte background = _backgroundPixels[_backgroundHead];
        _backgroundHead++;
        _backgroundCount--;

        immutable ObjectPixel object = _objectPixels[0];
        foreach (int i; 1 .. TILE_SIZE) {
            _objectPixels[i - 1] = _objectPixels[i];
        }
        _objectPixels[TILE_SIZE - 1] = ObjectPixel();

        immutable int x = _position - TILE_SIZE - _fineScroll;
        _position++;
        if (x < 0) {
            return;
        }

        _output[_outputCount] = ShiftedPixel(background, object, x, _dots);
        _outputCount++;
        if (x < SCREEN_WIDTH - 1) {
            return;
        }

        _done = true;
        _ended = true;
        _length = _dots;
    }

    // Returns the shade of a pixel, from 0 for white to 3 for black.
    // On DMG, disabling the background blanks both background and window to white.
    // A palette reads as the old and new value ORed together in the dot it is written.
    private ubyte mixPixel(const ShiftedPixel pixel) const {
        immutable ubyte control = registers(pixel.dot + CONTROL_DELAY, BACKGROUND_LEAD).control;
        immutable ubyte[3] palettes = registers(_dots, BACKGROUND_LEAD).palettes;
        immutable ubyte[3] previous = registers(_dots - 1, BACKGROUND_LEAD).palettes;

        immutable ubyte backgroundColor = (control & ControlFlag.ENABLE_BG) ? pixel.background : 0;

        immutable ObjectPixel object = pixel.object;
        immutable bool objectVisible = object.color && (control & ControlFlag.ENABLE_SPRITES);
        if (objectVisible && !(object.behindBackground && backgroundColor)) {
            immutable PaletteIndex index = object.palette1 ? PaletteIndex.OBJECT1 : PaletteIndex.OBJECT0;
            return paletteShade(palettes[index] | previous[index], object.color);
        }

        if (!(control & ControlFlag.ENABLE_BG)) {
            return 0;
        }

        return paletteShade(palettes[PaletteIndex.BACKGROUND] | previous[PaletteIndex.BACKGROUND], backgroundColor);
    }
}

private int objectHeight(immutable ubyte control) {
    return (control & ControlFlag.LARGE_SPRITES) ? TILE_SIZE * 2 : TILE_SIZE;
}

// Returns the 2-bit color of pixel x of a tile row, from its two bit planes.
private ubyte tilePixel(immutable ubyte low, immutable ubyte high, immutable int x) {
    immutable int bit = TILE_SIZE - 1 - x;
    return cast(ubyte)(((low >> bit) & 1) | (((high >> bit) & 1) << 1));
}

private ubyte paletteShade(immutable ubyte palette, immutable ubyte color) {
    return (palette >> (color * 2)) & 0x03;
}
