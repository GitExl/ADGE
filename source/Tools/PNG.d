module Tools.PNG;

import std.file;
import std.bitmanip;
import std.zlib;
import std.digest.crc;
import std.algorithm;
import std.math;


// Reads and writes non-interlaced greyscale PNG images, as used by test reference screenshots.
// Not a general PNG library. See https://www.w3.org/TR/png/

private immutable ubyte[8] SIGNATURE = [0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A];

// Length, type and CRC around each chunk's data.
private immutable size_t CHUNK_OVERHEAD = 12;

private immutable ubyte COLOR_TYPE_GREY = 0;

private enum Filter : ubyte {
    NONE,
    SUB,
    UP,
    AVERAGE,
    PAETH,
}

public struct GreyImage {
    uint width;
    uint height;
    ubyte[] pixels;
}

public GreyImage readPNG(string fileName) {
    return decodePNG(cast(ubyte[])read(fileName));
}

public void writePNG(string fileName, GreyImage image) {
    write(fileName, encodePNG(image));
}

public GreyImage decodePNG(const ubyte[] data) {
    if (data.length < SIGNATURE.length || data[0 .. SIGNATURE.length] != SIGNATURE) {
        throw new Exception("Not a PNG image.");
    }

    GreyImage image;
    uint bitDepth;
    ubyte[] compressed;
    size_t offset = SIGNATURE.length;
    while (offset + CHUNK_OVERHEAD <= data.length) {
        immutable size_t length = bigEndianToNative!uint(data[offset .. offset + 4][0 .. 4]);
        immutable string type = cast(string)data[offset + 4 .. offset + 8];
        const ubyte[] chunk = data[offset + 8 .. offset + 8 + length];
        offset += CHUNK_OVERHEAD + length;

        if (type == "IHDR") {
            image.width = bigEndianToNative!uint(chunk[0 .. 4][0 .. 4]);
            image.height = bigEndianToNative!uint(chunk[4 .. 8][0 .. 4]);
            bitDepth = chunk[8];
            if (chunk[9] != COLOR_TYPE_GREY || chunk[12] != 0) {
                throw new Exception("Only non-interlaced greyscale PNG images are supported.");
            }
        } else if (type == "IDAT") {
            compressed ~= chunk;
        } else if (type == "IEND") {
            break;
        }
    }

    immutable size_t stride = (image.width * bitDepth + 7) / 8;
    ubyte[] raw = cast(ubyte[])uncompress(compressed);
    if (raw.length < (stride + 1) * image.height) {
        throw new Exception("PNG image data is truncated.");
    }

    // Filters work on bytes, comparing against the byte one pixel to the left, or one byte for depths under 8.
    immutable size_t pixelBytes = max(1, bitDepth / 8);
    immutable uint maxSample = (1 << bitDepth) - 1;
    ubyte[] previous = new ubyte[stride];
    foreach (uint y; 0 .. image.height) {
        immutable Filter filter = cast(Filter)raw[y * (stride + 1)];
        ubyte[] row = raw[y * (stride + 1) + 1 .. (y + 1) * (stride + 1)];
        unfilterRow(filter, row, previous, pixelBytes);

        foreach (uint x; 0 .. image.width) {
            immutable size_t bit = x * bitDepth;
            immutable uint sample = (row[bit / 8] >> (8 - bitDepth - bit % 8)) & maxSample;
            image.pixels ~= cast(ubyte)(sample * 255 / maxSample);
        }

        previous = row;
    }

    return image;
}

private void unfilterRow(immutable Filter filter, ubyte[] row, const ubyte[] previous, immutable size_t pixelBytes) {
    foreach (size_t i; 0 .. row.length) {
        immutable int left = i >= pixelBytes ? row[i - pixelBytes] : 0;
        immutable int up = previous[i];
        immutable int upLeft = i >= pixelBytes ? previous[i - pixelBytes] : 0;

        final switch (filter) {
            case Filter.NONE:
                break;
            case Filter.SUB:
                row[i] += left;
                break;
            case Filter.UP:
                row[i] += up;
                break;
            case Filter.AVERAGE:
                row[i] += (left + up) / 2;
                break;
            case Filter.PAETH:
                row[i] += paeth(left, up, upLeft);
                break;
        }
    }
}

private int paeth(immutable int left, immutable int up, immutable int upLeft) {
    immutable int estimate = left + up - upLeft;
    immutable int distanceLeft = abs(estimate - left);
    immutable int distanceUp = abs(estimate - up);
    immutable int distanceUpLeft = abs(estimate - upLeft);
    if (distanceLeft <= distanceUp && distanceLeft <= distanceUpLeft) {
        return left;
    }
    if (distanceUp <= distanceUpLeft) {
        return up;
    }

    return upLeft;
}

// Writes 8-bit greyscale without filtering.
public ubyte[] encodePNG(GreyImage image) {
    ubyte[] raw;
    foreach (uint y; 0 .. image.height) {
        raw ~= Filter.NONE;
        raw ~= image.pixels[y * image.width .. (y + 1) * image.width];
    }

    ubyte[] header;
    header ~= nativeToBigEndian(image.width);
    header ~= nativeToBigEndian(image.height);
    header ~= [8, COLOR_TYPE_GREY, 0, 0, 0];

    return SIGNATURE ~ encodeChunk("IHDR", header) ~ encodeChunk("IDAT", compress(raw)) ~ encodeChunk("IEND", []);
}

private ubyte[] encodeChunk(string type, const ubyte[] data) {
    const ubyte[] typeAndData = cast(const ubyte[])type ~ data;
    ubyte[4] checksum = crc32Of(typeAndData);
    reverse(checksum[]);

    return nativeToBigEndian(cast(uint)data.length) ~ typeAndData ~ checksum;
}

unittest {
    GreyImage image = GreyImage(3, 2, [0x00, 0x55, 0xAA, 0xFF, 0x12, 0x34]);
    GreyImage decoded = decodePNG(encodePNG(image));
    assert(decoded == image);
}

// 2-bit greyscale scales to 8 bits. Rows use the Sub and Up filters.
// Generated with Python's zlib from these filtered rows:
//   [SUB, 0b00011011], [UP, 0b01000000]
// Decoded samples are row 0: 0 1 2 3, row 1: 1 1 2 3.
unittest {
    immutable ubyte[] png = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02, 0x02, 0x00, 0x00, 0x00, 0x00, 0x10, 0x73, 0x3A,
        0x1E, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x94, 0x66, 0x72, 0x00,
        0x00, 0x00, 0x9D, 0x00, 0x5F, 0x75, 0x32, 0xD1, 0x2F, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    ];
    GreyImage image = decodePNG(png);
    assert(image.width == 4);
    assert(image.height == 2);
    assert(image.pixels == [0x00, 0x55, 0xAA, 0xFF, 0x55, 0x55, 0xAA, 0xFF]);
}
