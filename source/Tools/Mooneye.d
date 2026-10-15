module Tools.Mooneye;

import std.stdio;
import std.file;
import std.algorithm;
import std.array;
import std.string;
import std.path;
import std.getopt;

import Core.CPU;
import Core.Gameboy;

import Tools.PNG;


// Runs mooneye-gb test ROMs headless, as fast as possible.
// Also runs screenshot tests like dmg-acid2 and mealybug-tearoom-tests, which signal completion the same way.
// Usage: dub run --config=mooneye --build=release -- [--dump=<directory>] <rom or directory>...
// --dump writes the screen of each failed screenshot test to the directory, as PNG.

// A ROM signals its result by executing LD B, B with these register values.
// See https://github.com/Gekkio/mooneye-test-suite/
private immutable ubyte[6] PASS_REGISTERS = [3, 5, 8, 13, 21, 34];

// Tests finish within a few emulated seconds, boot ROM included.
private immutable uint FRAME_LIMIT = 60 * 20;

// Failing ROMs print their reason to the background tilemap, with tile numbers matching ASCII.
private immutable ushort TILEMAP = 0x9800;
private immutable ushort TILEMAP_WIDTH = 32;
private immutable ushort SCREEN_COLUMNS = 20;
private immutable ushort SCREEN_ROWS = 18;

// Screenshot tests keep a reference image next to the ROM, named after the hardware model.
// Only DMG references are compared; a ROM with only other references is skipped.
private immutable string[] DMG_REFERENCES = ["-dmg.png", "_dmg_blob.png"];
private immutable string[] OTHER_REFERENCES = ["-cgb.png", "_cgb_c.png", "_cgb_d.png", "_dmg_b.png"];

private immutable uint SCREEN_WIDTH = 160;
private immutable uint SCREEN_HEIGHT = 144;
private immutable ubyte SHADE_MASK = 0x03;
private immutable uint GREY_PER_SHADE = 85;

// A ROM's file name ends in the hardware models it passes on, like "boot_div-dmgABCmgb" or "di_timing-GS".
// No suffix means all models. Each ROM runs on the first supported model it lists, in this order.
private struct Model {
    string tag;
    string mode;
    string bootROM;
}

private immutable Model[] MODELS = [
    Model("dmgABC", "dmg", "dmg"),
    Model("G", "dmg", "dmg"),
    Model("dmg0", "dmg", "dmg0"),
    Model("mgb", "mgb", "mgb"),
    Model("sgb2", "sgb2", "sgb2"),
    Model("sgb", "sgb", "sgb"),
    Model("S", "sgb", "sgb"),
];

private enum Result {
    PASS,
    FAIL,
    TIMEOUT,
    ERROR,
    SKIP,
}

private struct Report {
    string fileName;
    Result result;
    string detail;
}

int main(string[] args) {
    string dumpPath;
    getopt(args, "dump", &dumpPath);

    Report[] reports;
    foreach (string fileName; collectROMs(args[1 .. $])) {
        reports ~= runROM(fileName, dumpPath);
    }

    // Printed after all runs, so the emulator's own output doesn't interleave.
    writeln();
    foreach (Report report; reports) {
        writefln("%-7s %s %s", report.result, report.fileName, report.detail);
    }

    immutable size_t passed = reports.count!(r => r.result == Result.PASS);
    immutable size_t skipped = reports.count!(r => r.result == Result.SKIP);
    writefln("%d/%d passed, %d skipped", passed, reports.length - skipped, skipped);

    return passed + skipped == reports.length ? 0 : 1;
}

private string[] collectROMs(string[] paths) {
    string[] fileNames;
    foreach (string path; paths) {
        if (!isDir(path)) {
            fileNames ~= path;
            continue;
        }

        fileNames ~= dirEntries(path, "*.gb", SpanMode.depth).map!(e => e.name).array.sort.array;
    }

    return fileNames;
}

// Returns the model to run a ROM on, or null if none of the models it passes on is supported.
private immutable(Model)* selectModel(string fileName) {
    immutable string name = baseName(fileName, ".gb");
    immutable ptrdiff_t dash = name.lastIndexOf('-');
    if (dash < 0) {
        return &MODELS[0];
    }

    immutable string models = name[dash + 1 .. $];
    foreach (ref immutable Model model; MODELS) {
        if (models.canFind(model.tag)) {
            return &model;
        }
    }

    return null;
}

// Returns the reference image to compare a ROM's screen to, or null if the ROM is not a screenshot test.
private string findReference(string fileName) {
    foreach (string suffix; DMG_REFERENCES) {
        immutable string reference = stripExtension(fileName) ~ suffix;
        if (exists(reference)) {
            return reference;
        }
    }

    return null;
}

private bool hasOtherReference(string fileName) {
    return OTHER_REFERENCES.any!(suffix => exists(stripExtension(fileName) ~ suffix));
}

private Report runROM(string fileName, string dumpPath) {
    immutable string reference = findReference(fileName);
    if (!reference && hasOtherReference(fileName)) {
        return Report(fileName, Result.SKIP, "");
    }

    // A DMG reference image decides the model, whatever the file name says.
    immutable(Model)* model = reference ? &MODELS[0] : selectModel(fileName);
    if (!model) {
        return Report(fileName, Result.SKIP, "");
    }

    Gameboy gameboy = new Gameboy(model.mode, model.bootROM);

    // Screenshot tests may hit the breakpoint mid-frame, so the screen is captured at the next VBlank.
    bool finished;
    bool captured;
    Registers registers;
    string screen;
    ubyte[] shades;
    gameboy.lcd.vblankCallback = delegate void() {
        if (!finished || captured) {
            return;
        }
        captured = true;
        shades = readShades(gameboy);
    };
    gameboy.cpu.breakpointCallback = delegate void() {
        if (finished) {
            return;
        }
        finished = true;
        registers = gameboy.cpu.registers;
        screen = readScreenText(gameboy);
    };

    try {
        gameboy.loadCart(fileName);
        foreach (uint frame; 0 .. FRAME_LIMIT) {
            gameboy.executeFrame();
            if (finished && (captured || !reference)) {
                break;
            }
        }
    } catch (Exception e) {
        return Report(fileName, Result.ERROR, e.msg);
    }

    if (!finished || (reference && !captured)) {
        return Report(fileName, Result.TIMEOUT, "");
    }

    if (reference) {
        return compareScreen(fileName, reference, shades, dumpPath);
    }

    // On failure only the serial output carries the 0x42 fail marker, not the registers.
    immutable ubyte[6] values = [registers.B, registers.C, registers.D, registers.E, registers.H, registers.L];
    if (values == PASS_REGISTERS) {
        return Report(fileName, Result.PASS, "");
    }

    return Report(fileName, Result.FAIL, screen);
}

private Report compareScreen(string fileName, string reference, ubyte[] shades, string dumpPath) {
    GreyImage expected;
    try {
        expected = readPNG(reference);
    } catch (Exception e) {
        return Report(fileName, Result.ERROR, e.msg);
    }

    if (expected.width != SCREEN_WIDTH || expected.height != SCREEN_HEIGHT) {
        return Report(fileName, Result.ERROR, "Reference image is not screen sized.");
    }

    size_t differences;
    foreach (size_t i, ubyte shade; shades) {
        if (greyToShade(expected.pixels[i]) != shade) {
            differences++;
        }
    }

    if (!differences) {
        return Report(fileName, Result.PASS, "");
    }

    if (dumpPath) {
        mkdirRecurse(dumpPath);
        writePNG(buildPath(dumpPath, baseName(fileName, ".gb") ~ ".png"), shadesToImage(shades));
    }

    return Report(fileName, Result.FAIL, format("%d pixels differ", differences));
}

// DMG shades run from 0 for white to 3 for black.
private ubyte[] readShades(Gameboy gameboy) {
    return gameboy.lcd.buffer.map!(pixel => cast(ubyte)(pixel & SHADE_MASK)).array;
}

private ubyte greyToShade(immutable ubyte grey) {
    return cast(ubyte)((255 - grey + GREY_PER_SHADE / 2) / GREY_PER_SHADE);
}

private GreyImage shadesToImage(ubyte[] shades) {
    ubyte[] pixels = shades.map!(shade => cast(ubyte)(255 - shade * GREY_PER_SHADE)).array;
    return GreyImage(SCREEN_WIDTH, SCREEN_HEIGHT, pixels);
}

// Returns the non-empty lines of text on screen, each on a new indented line.
private string readScreenText(Gameboy gameboy) {
    string text;
    foreach (ushort row; 0 .. SCREEN_ROWS) {
        char[] line;
        foreach (ushort column; 0 .. SCREEN_COLUMNS) {
            immutable ubyte tile = gameboy.lcd.readVRAM(cast(ushort)(TILEMAP + row * TILEMAP_WIDTH + column));
            line ~= (tile >= ' ' && tile <= '~') ? cast(char)tile : ' ';
        }

        immutable string trimmed = line.stripRight.idup;
        if (trimmed.length) {
            text ~= "
        " ~ trimmed;
        }
    }

    return text;
}
