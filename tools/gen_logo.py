#!/usr/bin/env python3
"""Gera assets/logo.svg e logo-light.svg (o mascote Terminal, o principal, mais o nome)
a partir de assets/mascote-terminal.svg, com o texto "larperCord" convertido em curvas
(Inter), e assets/icon-classico.svg (o ícone do mascote Clássico) a partir de
assets/logo-mark.svg. O site usa cópias de logo*.svg em docs/assets/."""
import re, sys
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.varLib.instancer import instantiateVariableFont

root = Path(__file__).resolve().parent.parent
font_path = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/fonts/inter/InterVariable.ttf"
font = instantiateVariableFont(TTFont(font_path), {"wght": 780, "opsz": 32}, inplace=False)
cmap, gs = font.getBestCmap(), font.getGlyphSet()
upm = font["head"].unitsPerEm
hmtx = font["hmtx"]

def word(text, x, baseline, size, tracking=-0.02):
    """Path SVG do texto e a largura usada."""
    scale = size / upm
    pen = SVGPathPen(gs)
    cx = 0.0
    for ch in text:
        g = cmap[ord(ch)]
        tp = TransformPen(pen, (scale, 0, 0, -scale, x + cx, baseline))
        gs[g].draw(tp)
        cx += hmtx[g][0] * scale + tracking * size
    return pen.getCommands(), cx - tracking * size

def parts(name):
    """O <defs> e tudo depois dele (o desenho), no espaço do viewBox do arquivo."""
    src = (root / name).read_text()
    return re.search(r"<defs>.*?</defs>", src, re.S).group(0), src.split("</defs>", 1)[1].rsplit("</svg>", 1)[0]

defs, body = parts("assets/mascote-terminal.svg")
VB = (-10, -34, 147.14, 134)

# Lockup horizontal: símbolo com 160 de altura + texto.
H = 160
s = H / VB[3]
MW = VB[2] * s
size = 92
base = H / 2 + size * 0.36
p1, w1 = word("larper", MW + 22, base, size)
p2, w2 = word("Cord", MW + 22 + w1 + size * 0.01, base, size)
W = int(MW + 22 + w1 + w2 + 24)
for theme, ink in (("", "#F4F1FF"), ("-light", "#17112E")):
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 {W} {H}" width="{W}" height="{H}">
  <title>larperCord</title>
  {defs.replace("</defs>", f'''  <linearGradient id="lc-word" gradientUnits="userSpaceOnUse" x1="{MW + 22 + w1:.0f}" y1="0" x2="{W:.0f}" y2="{H}">
      <stop offset="0" stop-color="#A855FF"/><stop offset="1" stop-color="#F03CFF"/>
    </linearGradient>
  </defs>''')}
  <g transform="scale({s:.5f}) translate({-VB[0]} {-VB[1]})">
  {body}
  </g>
  <path d="{p1}" fill="{ink}"/>
  <path d="{p2}" fill="url(#lc-word)"/>
</svg>
'''
    (root / f"assets/logo{theme}.svg").write_text(svg)

# O ícone do Clássico: o símbolo num quadrado arredondado escuro.
defs, body = parts("assets/logo-mark.svg")
icon = f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 512 512" width="512" height="512">
  <title>larperCord</title>
  {defs.replace("</defs>", '''  <radialGradient id="lc-bg" cx="0.3" cy="0.2" r="0.95">
      <stop offset="0" stop-color="#2A1F55"/><stop offset="1" stop-color="#0E0B1A"/>
    </radialGradient>
  </defs>''')}
  <rect width="512" height="512" rx="116" fill="url(#lc-bg)"/>
  <g transform="translate(28 85) scale(0.38) translate(-100 -110)">
  {body}
  </g>
</svg>
'''
(root / "assets/icon-classico.svg").write_text(icon)
print("ok:", W, "x", H)
