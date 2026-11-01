#!/usr/bin/env python3
"""Generate font16x16.bin (and optionally font16x16.png).

Format: 128 chars (ASCII 0..127), 16x16 bits each = 32 bytes/char.
Each row is 16 bits, big-endian, MSB = leftmost pixel.
In the final file the two 16-bit words of every 32-bit dword are swapped,
i.e. row 1 comes before row 0, row 3 before row 2, ...
"""
from PIL import Image, ImageDraw, ImageFont

FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
SIZE = 18
OUT_BIN = "font16x16.bin"
OUT_PNG = "font16x16.png"


def render_glyph(font, yoff, c):
    img = Image.new("1", (16, 16), 0)
    if 33 <= c < 127:
        d = ImageDraw.Draw(img)
        d.fontmode = "1"  # no anti-aliasing
        w = d.textlength(chr(c), font=font)
        d.text(((16 - w) / 2, yoff), chr(c), font=font, fill=1)
    return img


def glyph_rows(img):
    rows = []
    for y in range(16):
        v = 0
        for x in range(16):
            v = (v << 1) | (1 if img.getpixel((x, y)) else 0)
        rows.append(v)
    return rows


def main():
    font = ImageFont.truetype(FONT, SIZE)
    yoff = 1 - font.getbbox("A")[1]  # cap top at row 1

    out = bytearray()
    for c in range(128):
        rows = glyph_rows(render_glyph(font, yoff, c))
        # swap the 16-bit words of each 32-bit dword (row pairs)
        for i in range(0, 16, 2):
            out += rows[i + 1].to_bytes(2, "big")
            out += rows[i].to_bytes(2, "big")
    open(OUT_BIN, "wb").write(out)

    # PNG preview: undo the swap so glyphs appear upright
    d = bytes(out)
    cols, s, pad = 16, 4, 1
    n = len(d) // 32
    nrows = (n + cols - 1) // cols
    cw = 16 * s + pad
    img = Image.new("RGB", (cols * cw + pad, nrows * cw + pad), (60, 60, 60))
    px = img.load()
    for c in range(n):
        ox, oy = pad + (c % cols) * cw, pad + (c // cols) * cw
        for y in range(16):
            base = c * 32 + (y ^ 1) * 2  # y^1 undoes the row-pair swap
            v = int.from_bytes(d[base:base + 2], "big")
            for x in range(16):
                col = (255, 255, 255) if (v >> (15 - x)) & 1 else (0, 0, 0)
                for dy in range(s):
                    for dx in range(s):
                        px[ox + x * s + dx, oy + y * s + dy] = col
    img.save(OUT_PNG)


if __name__ == "__main__":
    main()
