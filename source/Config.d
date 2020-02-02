module Config;

import std.json;
import std.file;


public final class Config {

    private JSONValue[string] _values;

    public this(string fileName) {
        JSONValue root = parseJSON(readText(fileName));

        foreach (string key, JSONValue value; root.object) {
            if (value.type != JSONType.object) {
                throw new Exception("Root config values must be objects.");
            }

            foreach (string subKey, JSONValue subValue; value.object) {
                _values[key ~ "." ~ subKey] = subValue;
            }
        }
    }

    public JSONValue get(string key) {
        return _values[key];
    }

}