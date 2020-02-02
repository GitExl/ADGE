module Palette;

import std.json;
import std.conv;
import std.file;


public final class Palette {
    private ubyte[3] _border;
    private ubyte[3][4] _screen;

    public void read(string name) {
        JSONValue data = parseJSON(readText("palette/" ~ name ~ ".json"));
        if (data.type != JSONType.OBJECT) {
            throw new Exception("Palette file must contain an object.");
        }

        if (data["border"].type != JSONType.ARRAY || data["border"].array.length != 3) {
            throw new Exception("Palette border color must be an array of 3 values.");
        }
        JSONValue borderValues = data["border"].array;
        _border[0] = borderValues[0].str.to!ubyte(16);
        _border[1] = borderValues[1].str.to!ubyte(16);
        _border[2] = borderValues[2].str.to!ubyte(16);

        if (data["screen"].type != JSONType.ARRAY || data["screen"].array.length != 12) {
            throw new Exception("Palette screen colors must be an array of 12 values.");
        }

        int index = 0;
        foreach (JSONValue value; data["screen"].array) {
            if (value.type != JSONType.STRING) {
                throw new Exception("Palette file must contain an array of strings.");
            }

            _screen[index / 3][index % 3] = value.str.to!ubyte(16);
            index++;
        }
    }

    @property
    public ubyte[3] border() {
        return _border;
    }

    @property
    public ubyte[3][4] screen() {
        return _screen;
    }
}
