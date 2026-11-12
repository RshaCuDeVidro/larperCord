#!/usr/bin/env python3
"""Gera os ícones derivados dos SVGs dos dois mascotes:

  Terminal (o principal): assets/icon-terminal.svg (com a placa escura),
  assets/mascote-terminal.svg (só o mascote) e assets/mascote-terminal-pequeno.svg
  (traços grossos para 16 a 32 px).
  Clássico (o da cara de deboche): assets/icon-classico.svg e assets/logo-mark.svg.

  assets/icon-64.png, icon-classico-64.png    ícone da janela (embutido no executável)
  assets/icon-32.png, icon-classico-32.png    ícone da bandeja (embutido): só o mascote,
                                              sem a placa escura, que em 22 px come metade do desenho
  assets/icon-128.png, icon-classico-128.png  o ícone do menu de aplicativos no Linux, que o app
                                              grava na pasta de ícones do usuário (embutido)
  assets/icon.ico, icon-classico.ico          ícone do .exe e da bandeja no Windows (ver assets/larpercord.rc)
  docs/assets/icon-32.png, icon-64.png, icon-180.png  o site, o instalador e o AUR (o principal)

Precisa de rsvg-convert e de Pillow. Rodar de novo só se os SVGs mudarem:
    python3 tools/gen_icons.py
"""
import io
import struct
import subprocess
from pathlib import Path

from PIL import Image

root = Path(__file__).resolve().parent.parent
assets = root / "assets"


def render(svg, size):
    """O SVG em `size`x`size`, centrado e sem deformar."""
    png = subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), "--keep-aspect-ratio", str(svg)],
        check=True,
        capture_output=True,
    ).stdout
    src = Image.open(io.BytesIO(png)).convert("RGBA")
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(src, ((size - src.width) // 2, (size - src.height) // 2))
    return out


def small(img, colors=128):
    """PNG com paleta (o stb_image lê a transparência): um terço do tamanho."""
    buf = io.BytesIO()
    img.quantize(colors, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE).save(buf, "PNG", optimize=True)
    return buf.getvalue()


def rgba_png(img, colors=None):
    """PNG de 32 bits: é o que o Windows garante ler dentro de um .ico."""
    if colors:
        img = img.quantize(colors, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE).convert("RGBA")
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def ico(entries):
    """Cabeçalho do .ico seguido dos PNGs (Windows Vista em diante)."""
    head = struct.pack("<HHH", 0, 1, len(entries))
    offset = len(head) + 16 * len(entries)
    table = b""
    body = b""
    for size, png in entries:
        table += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(png), offset)
        body += png
        offset += len(png)
    return head + table + body


docs = root / "docs" / "assets"
sets = {
    "": (assets / "icon-terminal.svg", assets / "mascote-terminal-pequeno.svg"),
    "-classico": (assets / "icon-classico.svg", assets / "logo-mark.svg"),
}
written = []
for suffix, (icon, mark) in sets.items():
    for name, data in (
        (f"icon{suffix}-64.png", small(render(icon, 64))),
        (f"icon{suffix}-32.png", small(render(mark, 32))),
        (f"icon{suffix}-128.png", small(render(icon, 128), 192)),
        (
            f"icon{suffix}.ico",
            ico(
                [
                    (16, rgba_png(render(mark, 16))),
                    (24, rgba_png(render(mark, 24))),
                    (32, rgba_png(render(icon, 32))),
                    (48, rgba_png(render(icon, 48))),
                    (256, rgba_png(render(icon, 256), 192)),
                ]
            ),
        ),
    ):
        (assets / name).write_bytes(data)
        written.append(assets / name)
# O site, o instalador (install.sh) e o AUR usam o principal.
main_icon = sets[""][0]
for size in (32, 64, 180):
    (docs / f"icon-{size}.png").write_bytes(rgba_png(render(main_icon, size), 192))
    written.append(docs / f"icon-{size}.png")
for path in written:
    print(path.relative_to(root), path.stat().st_size, "bytes")
