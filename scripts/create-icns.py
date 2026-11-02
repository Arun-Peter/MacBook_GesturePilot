#!/usr/bin/env python3
"""Build a modern ICNS container from PNG files in an iconset directory."""

from pathlib import Path
import struct
import sys


ICON_ENTRIES = (
    (b"ic04", "icon_16x16.png"),
    (b"ic05", "icon_32x32.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
    (b"ic11", "icon_16x16@2x.png"),
    (b"ic12", "icon_32x32@2x.png"),
    (b"ic13", "icon_128x128@2x.png"),
    (b"ic14", "icon_256x256@2x.png"),
)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: create-icns.py ICONSET OUTPUT.icns", file=sys.stderr)
        return 2

    iconset = Path(sys.argv[1])
    output = Path(sys.argv[2])
    chunks = []

    for icon_type, filename in ICON_ENTRIES:
        data = (iconset / filename).read_bytes()
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError(f"{filename} is not a PNG file")
        chunks.append(icon_type + struct.pack(">I", len(data) + 8) + data)

    payload = b"".join(chunks)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
