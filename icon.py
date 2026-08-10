#!/usr/bin/env python3
"""Genererer Resources/AppIcon.icns fra et 16x16 pikselrutenett.

8-bits mikrofon i gammeldags stil. Kilden er rutenettet under — rediger det,
kjør `python3 icon.py`, og alle ikonstørrelsene bygges på nytt.

16x16 er valgt fordi hver .icns-størrelse da blir et heltallsmultiplum
(16, 32, 64, 128, 256, 512, 1024), så nærmeste-nabo-skalering gir skarpe
piksler uten interpolasjon. Det er hele poenget med 8-bits-uttrykket.
"""
import os, struct, zlib, subprocess, shutil, sys

# . = bakgrunnsflis  K = kontur  S = lys krom  M = krom  D = mørk krom  R = av-på-lampe
SPRITE = [
    "................",
    "......KKKK......",
    ".....KSSSSK.....",
    "....KSMDMDSK....",
    "....KSDMDMSK....",
    "....KSMDMDSK....",
    "....KSDMDMSK....",
    "....KSMDMDSK....",
    ".....KSSSSK.....",
    "......KKKK......",
    "......KMMK......",
    "......KMMK......",
    "......KMMK......",
    ".....KMMMMK.....",
    "....KSMMMMSK....",
    "....KKKKKKKK....",
]

PALETTE = {
    "K": (0x14, 0x16, 0x1C, 255),   # kontur
    "S": (0xF2, 0xF3, 0xF7, 255),   # lys krom
    "M": (0xB4, 0xB8, 0xC6, 255),   # krom
    "D": (0x71, 0x77, 0x8A, 255),   # mørk krom
    "R": (0xE0, 0x53, 0x3D, 255),   # lampe
    ".": None,                       # bakgrunnsflis
}
BG = (0x2D, 0x40, 0x59, 255)        # stålblå flis, flat — tofarget delte ikonet i to

# Avrundede hjørner: trappetrinn på to piksler, samme lesning som macOS-squircle.
CORNER_CUTS = {(0, 0), (1, 0), (0, 1)}

N = len(SPRITE)


def base_pixels():
    """Returnerer N*N liste av RGBA-tupler."""
    out = []
    for y, row in enumerate(SPRITE):
        assert len(row) == N, f"rad {y} er {len(row)} bred, forventet {N}"
        for x, ch in enumerate(row):
            cut = (min(x, N - 1 - x), min(y, N - 1 - y)) in CORNER_CUTS
            if cut:
                out.append((0, 0, 0, 0))
                continue
            fg = PALETTE[ch]
            out.append(fg if fg else BG)
    return out


def write_png(path, pixels, size, scale):
    """Nærmeste nabo-skalering + minimal PNG-skriver (ingen avhengigheter)."""
    rows = []
    for y in range(size):
        row = bytearray([0])  # filtertype 0
        sy = y // scale
        for x in range(size):
            row += bytes(pixels[sy * N + x // scale])
        rows.append(bytes(row))
    raw = zlib.compress(b"".join(rows), 9)

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", raw))
        f.write(chunk(b"IEND", b""))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    iconset = os.path.join(here, "AppIcon.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)

    pixels = base_pixels()
    # (filnavn, pikselstørrelse) — iconutil krever nøyaktig disse navnene
    for name, size in [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]:
        assert size % N == 0, f"{size} er ikke et multiplum av {N}"
        write_png(os.path.join(iconset, name + ".png"), pixels, size, size // N)

    out = os.path.join(here, "Resources", "AppIcon.icns")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    shutil.rmtree(iconset, ignore_errors=True)
    print(f"ok: {os.path.relpath(out, here)}")


if __name__ == "__main__":
    sys.exit(main())
