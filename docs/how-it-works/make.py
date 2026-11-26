#!/usr/bin/env python3
"""Draws the "how it works" picture in the READMEs, one per language.

    python3 make.py

draws each picture as an .svg and has Google Chrome render it to
how-it-works-<lang>.png, at twice the size, next to this file. The READMEs
show the .png: an .svg would be drawn with whatever fonts the reader happens
to have. Without Chrome the .svg files are left behind instead.
"""
import pathlib
import subprocess

HERE = pathlib.Path(__file__).parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

BG, PANEL, INK, MUTED, TEAL, KEY, LINE = "#16181d", "#1f2229", "#f4f5f7", "#8b90a0", "#3fd9c4", "#555a6b", "#353945"
# The language's own font comes first, or its glyphs come from two fonts of different weight.
FONTS = {"ko": "'Apple SD Gothic Neo'", "ja": "'Hiragino Sans'", "en": "'Apple SD Gothic Neo'"}
FALLBACK = "-apple-system,'Helvetica Neue',Arial,sans-serif"

TEXT = {
    "en": dict(title="Your keyboard follows your eyes", sub="GazeSwitch · with or without a cable",
               left="Look at the MacBook", right="Look at the other computer", mac="This Mac", other="Other computer",
               bt="Bluetooth", foot="A macOS menu bar app for ZMK keyboards"),
    "ko": dict(title="보는 화면으로 키보드가 따라갑니다", sub="GazeSwitch · 케이블이 있든 없든",
               left="맥북을 보면", right="옆 컴퓨터를 보면", mac="이 Mac", other="다른 컴퓨터",
               bt="블루투스", foot="ZMK 키보드용 macOS 메뉴바 앱"),
    "ja": dict(title="見ている画面にキーボードがついてきます", sub="GazeSwitch · ケーブルがあってもなくても",
               left="MacBook を見ると", right="もう一台を見ると", mac="この Mac", other="もう一台",
               bt="Bluetooth", foot="ZMK キーボード用の macOS メニューバーアプリ"),
}


def screen(x, y, active, laptop, label):
    stroke = TEAL if active else LINE
    fill = "#1d3a39" if active else "#1a1c22"
    out = [f'<rect x="{x}" y="{y}" width="250" height="160" rx="12" fill="{fill}" stroke="{stroke}" stroke-width="{4 if active else 3}"/>']
    if active:  # lines of text being typed, with a cursor
        for i, w in enumerate((150, 190, 90)):
            out.append(f'<rect x="{x+30}" y="{y+42+i*30}" width="{w}" height="10" rx="5" fill="{TEAL}" opacity="{0.9 if i == 2 else 0.45}"/>')
        out.append(f'<rect x="{x+128}" y="{y+94}" width="5" height="26" rx="2" fill="{INK}"/>')
    if laptop:
        out.append(f'<path d="M{x-22} {y+168} h294 l-14 14 h-266 z" fill="{stroke}"/>')
    else:
        out.append(f'<rect x="{x+113}" y="{y+162}" width="24" height="16" fill="{stroke}"/>')
        out.append(f'<rect x="{x+75}" y="{y+176}" width="100" height="7" rx="3.5" fill="{stroke}"/>')
    out.append(f'<text x="{x+125}" y="{y+218}" text-anchor="middle" font-size="24" font-weight="600" fill="{INK if active else MUTED}">{label}</text>')
    return "".join(out)


def half(cx, cy, lit, tilt):
    color = TEAL if lit else KEY
    keys = "".join(f'<rect x="{dx}" y="{dy}" width="34" height="34" rx="8" fill="{color}"/>'
                   for dx in (-37, 3) for dy in (-37, 3))
    return f'<g transform="translate({cx} {cy}) rotate({tilt})">{keys}</g>'


def panel(x, y, t, look_left):
    ax = 185 if look_left else 535          # centre of the screen being looked at
    pupil = -9 if look_left else 9
    kx = 300 if look_left else 420          # the keyboard half on that side
    side = -1 if look_left else 1
    link = f"M{kx + side*52} 452 C{ax + side*150} 440 {ax + side*165} 330 {ax + side*88} 262"
    bx, by = ax + side*93, 372
    out = [f'<g transform="translate({x} {y})">',
           f'<rect width="720" height="560" rx="28" fill="{PANEL}"/>',
           f'<text x="360" y="58" text-anchor="middle" font-size="30" font-weight="700" fill="{INK}">{t["left"] if look_left else t["right"]}</text>',
           screen(60, 92, look_left, True, t["mac"]),
           screen(410, 92, not look_left, False, t["other"]),
           # gaze
           f'<path d="M{360 + side*34} 372 L{ax - side*40} 326" stroke="{INK}" stroke-width="3" stroke-dasharray="3 9" stroke-linecap="round" fill="none"/>',
           f'<path d="M318 390 Q360 352 402 390 Q360 428 318 390 Z" fill="{INK}"/>',
           f'<circle cx="{360 + pupil}" cy="390" r="15" fill="{BG}"/><circle cx="{360 + pupil}" cy="390" r="6" fill="{INK}"/>',
           # keyboard
           half(300, 480, look_left, -6), half(420, 480, not look_left, 6),
           # wireless link
           f'<path d="{link}" stroke="{TEAL}" stroke-width="4" stroke-dasharray="2 11" stroke-linecap="round" fill="none"/>',
           f'<rect x="{bx-62}" y="{by-19}" width="124" height="38" rx="19" fill="{PANEL}" stroke="{TEAL}" stroke-width="2"/>',
           f'<text x="{bx}" y="{by+7}" text-anchor="middle" font-size="19" font-weight="600" fill="{TEAL}">{t["bt"]}</text>',
           '</g>']
    return "".join(out)


def draw(lang):
    t = TEXT[lang]
    return "".join([
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 900" width="1600" height="900" font-family="{FONTS[lang]},{FALLBACK}">',
        f'<rect width="1600" height="900" fill="{BG}"/>',
        f'<text x="800" y="112" text-anchor="middle" font-size="60" font-weight="800" fill="{INK}">{t["title"]}</text>',
        f'<text x="800" y="170" text-anchor="middle" font-size="30" font-weight="600" fill="{TEAL}">{t["sub"]}</text>',
        panel(60, 220, t, True), panel(820, 220, t, False),
        f'<text x="800" y="850" text-anchor="middle" font-size="24" fill="{MUTED}">{t["foot"]}</text>',
        '</svg>'])


for lang in TEXT:
    svg = HERE / f"how-it-works-{lang}.svg"
    svg.write_text(draw(lang))
    if pathlib.Path(CHROME).exists():
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                        "--force-device-scale-factor=2", "--window-size=1600,900",
                        f"--screenshot={svg.with_suffix('.png')}", svg.as_uri()],
                       check=True, capture_output=True)
        svg.unlink()
