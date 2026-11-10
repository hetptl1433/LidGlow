#!/usr/bin/python3
"""Package the generated PNG representations into a standard macOS icon resource."""
from pathlib import Path
import struct
import sys

folder = Path(sys.argv[1])
representations = [
    (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
    (b"ic11", "icon_16x16@2x.png"),
    (b"ic12", "icon_32x32@2x.png"),
    (b"ic13", "icon_128x128@2x.png"),
    (b"ic14", "icon_256x256@2x.png"),
]
chunks = []
for code, name in representations:
    data = (folder / name).read_bytes()
    chunks.append(code + struct.pack(">I", len(data) + 8) + data)
body = b"".join(chunks)
Path(sys.argv[2]).write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
