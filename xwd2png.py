#!/usr/bin/python3 -I
"""Convert an X window dump (xwd, ZPixmap 24/32 bpp) to PNG: xwd2png.py <in.xwd> <out.png>"""
import struct
import sys

from PIL import Image

data = open(sys.argv[1], "rb").read()
h = struct.unpack(">25I", data[:100])
header_size, fmt, width, height = h[0], h[2], h[4], h[5]
byte_order, bpp, bytes_per_line, ncolors = h[7], h[11], h[12], h[19]
if fmt != 2 or bpp not in (24, 32):
    sys.exit(f"unsupported xwd: format {fmt}, {bpp} bpp")
pixels = data[header_size + 12 * ncolors:]
mode = ("BGRX" if byte_order == 0 else "XRGB") if bpp == 32 else ("BGR" if byte_order == 0 else "RGB")
Image.frombuffer("RGB", (width, height), pixels, "raw", mode, bytes_per_line, 1).save(sys.argv[2])
