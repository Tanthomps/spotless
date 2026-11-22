#!/usr/bin/env python3
"""RETIRED (2026-11): the mark is now site/assets/spotless.svg (play triangle, green), and covers
draw the app icon small. `ship` would bring back the old pink note; don't run it.

Spotless brand mark: ONE master SVG, every icon and logo generated from it (stdlib + macOS).

    python3 scripts/brand/final.py master      # construct the mark -> assets/brand/spotless.svg
    python3 scripts/brand/gen-brand.py ship    # master -> every app target

The master (assets/brand/spotless.svg, a 100 box) is a black tile (`<rect id="bg">`), a dark-pink
disc (`<circle id="disc">`, r 40 = 80 % of the tile) and a black beamed note (`<path id="note">`).
The Mac and iPhone icons draw exactly this; only the platform frame differs (iOS full bleed,
masked by the system; macOS on Apple's 824/1024 grid with its shadow; elsewhere the same square
with a 22.4 % radius). In the app and on Made For You covers the mark is the disc and note
without the tile. Rasterised by svg2png.swift (NSImage's SVG renderer). The disc colour is
checked against Spotify's greens (CIEDE2000 >= 15).

`ship` writes src-tauri/icons/* (.icns, PNGs, .ico, Square*Logo, tray-template), the iOS AppIcon,
launch mark (LAUNCH) and SpotlessGlyph assets, ui favicon.svg, and rewrites the inlined copies (lines
tagged `gen-brand`) in Logo.svelte, mfy.rs, devmock smart2.ts and MadeForYou.swift.
"""
import json, math, os, re, shutil, struct, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# The launch screen's image asset. iOS caches launch screens by what they reference, so a changed
# mark under the same name can keep showing the old one: bump the name (and Info.plist's
# UILaunchScreen UIImageName, and LaunchCover in EncoreApp.swift) whenever the mark changes.
LAUNCH = "LaunchMark2"
HERE = Path(__file__).resolve().parent

# --- colour distance from Spotify ----------------------------------------------------------------

SPOTIFY = ["#1ED760", "#1DB954"]


def _lab(hexc):
    h = hexc.lstrip("#")
    rgb = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    lin = [((c + 0.055) / 1.055) ** 2.4 if c > 0.04045 else c / 12.92 for c in rgb]
    x = (0.4124 * lin[0] + 0.3576 * lin[1] + 0.1805 * lin[2]) / 0.95047
    y = 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    z = (0.0193 * lin[0] + 0.1192 * lin[1] + 0.9505 * lin[2]) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 216 / 24389 else (24389 / 27 * t + 16) / 116
    return 116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))


def de2000(c1, c2):
    L1, a1, b1 = _lab(c1)
    L2, a2, b2 = _lab(c2)
    C1, C2 = math.hypot(a1, b1), math.hypot(a2, b2)
    Cb = (C1 + C2) / 2
    G = 0.5 * (1 - math.sqrt(Cb ** 7 / (Cb ** 7 + 25 ** 7)))
    a1p, a2p = a1 * (1 + G), a2 * (1 + G)
    C1p, C2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    h1p = math.degrees(math.atan2(b1, a1p)) % 360
    h2p = math.degrees(math.atan2(b2, a2p)) % 360
    dL, dC = L2 - L1, C2p - C1p
    dh = h2p - h1p
    if C1p * C2p == 0: dh = 0
    elif dh > 180: dh -= 360
    elif dh < -180: dh += 360
    dH = 2 * math.sqrt(C1p * C2p) * math.sin(math.radians(dh / 2))
    Lb, Cbp = (L1 + L2) / 2, (C1p + C2p) / 2
    hb = h1p + h2p
    if C1p * C2p != 0:
        hb = (hb + 360) / 2 if abs(h1p - h2p) > 180 else hb / 2
        if abs(h1p - h2p) > 180 and h1p + h2p >= 360: hb -= 360
    T = (1 - 0.17 * math.cos(math.radians(hb - 30)) + 0.24 * math.cos(math.radians(2 * hb))
         + 0.32 * math.cos(math.radians(3 * hb + 6)) - 0.20 * math.cos(math.radians(4 * hb - 63)))
    SL = 1 + 0.015 * (Lb - 50) ** 2 / math.sqrt(20 + (Lb - 50) ** 2)
    SC, SH = 1 + 0.045 * Cbp, 1 + 0.015 * Cbp * T
    RT = (-2 * math.sqrt(Cbp ** 7 / (Cbp ** 7 + 25 ** 7))
          * math.sin(math.radians(60 * math.exp(-(((hb - 275) / 25) ** 2)))))
    return math.sqrt((dL / SL) ** 2 + (dC / SC) ** 2 + (dH / SH) ** 2 + RT * (dC / SC) * (dH / SH))


def _mix(c1, c2, t):
    a = [int(c1[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(c2[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x + (y - x) * t):02X}" for x, y in zip(a, b))


def check_colours(name, colours):
    """Every colour, and every step of each gradient, must sit >= 15 ΔE00 from Spotify green."""
    worst = (999.0, "", "")
    for c in colours:
        stops = [c] if isinstance(c, str) else [_mix(c[0], c[1], i / 10) for i in range(11)]
        for s in stops:
            for g in SPOTIFY:
                d = de2000(s, g)
                if d < worst[0]: worst = (d, s, g)
    assert worst[0] >= 15, f"{name}: {worst[1]} is ΔE00 {worst[0]:.1f} from {worst[2]}"
    return worst


# --- marks ---------------------------------------------------------------------------------------
#
# The MASTER is an SVG in a 100 box: a full-bleed tile (`<rect id="bg">`) and the mark
# (`<g id="mark">`: `<circle id="disc">` + `<path id="note">`). Every icon draws exactly this;
# only the platform frame differs (iOS: full bleed, the system masks it; macOS: on Apple's grid;
# everywhere else: the same square with radius 22.4 %).

MASTER = ROOT / "assets/brand/spotless.svg"
RADIUS = 22.4  # corner radius in the 100 box, used by every rounded rendering


def parse_master(text):
    bg = re.search(r'<rect id="bg"[^>]*fill="(#[0-9A-Fa-f]{6})"', text).group(1)
    mark = re.search(r'<g id="mark">(.*)</g></svg>', text, re.S).group(1)
    return bg, mark


def framed(master, x, y, size, radius=RADIUS):
    """The master at (x, y), `size` wide: background square with `radius` (in the 100 box), glyph."""
    bg, mark = parse_master(master)
    s = size / 100
    return (f'<g transform="translate({x:.2f} {y:.2f}) scale({s:.4f})">'
            f'<rect width="100" height="100" rx="{radius}" fill="{bg}"/>{mark}</g>')


def svg(w, h, body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{body}</svg>'


def mac_icon(master):
    """macOS grid at 1024: 824 tile, 100 px margin (shadow added when rendered)."""
    return svg(1024, 1024, framed(master, 100, 100, 824))


def ios_icon(master):
    """Full bleed: iOS applies its own mask."""
    return svg(1024, 1024, framed(master, 0, 0, 1024, 0))


def mark_colours(master):
    bg, mark = parse_master(master)
    return [bg] + re.findall(r'(?:fill|stroke)="(#[0-9A-Fa-f]{6})"', mark)


# --- rendering -----------------------------------------------------------------------------------

class Renderer:
    def __init__(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="spotless-brand-"))
        self.bin = self.tmp / "svg2png"
        subprocess.run(["swiftc", "-O", "-o", str(self.bin), str(HERE / "svg2png.swift")], check=True)
        self.jobs, self.n = [], 0

    def add(self, svg_text, out, size, *flags):
        self.n += 1
        src = self.tmp / f"{self.n}.svg"
        src.write_text(svg_text)
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        self.jobs.append(f"{src} {out} {size} {' '.join(flags)}".strip())

    def run(self):
        subprocess.run([str(self.bin)], input="\n".join(self.jobs) + "\n", text=True, check=True)
        self.jobs = []

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


# --- ship ----------------------------------------------------------------------------------------

def write_ico(path, pngs):
    """ICO with embedded PNGs (Vista+), sizes ascending."""
    hdr = struct.pack("<HHH", 0, 1, len(pngs))
    off = 6 + 16 * len(pngs)
    ents, data = b"", b""
    for size, blob in pngs:
        s = 0 if size >= 256 else size
        ents += struct.pack("<BBBBHHII", s, s, 0, 0, 1, 32, len(blob), off + len(data))
        data += blob
    path.write_bytes(hdr + ents + data)


def sync_line(path, prefix, line):
    """Replace the one line in `path` that starts with `prefix` (after indentation) and ends with
    the `gen-brand` tag."""
    p = ROOT / path
    lines = p.read_text().split("\n")
    hits = [i for i, l in enumerate(lines) if l.strip().startswith(prefix) and l.rstrip().endswith("gen-brand")]
    assert len(hits) == 1, f"{path}: expected one '{prefix} ... gen-brand' line, found {len(hits)}"
    indent = lines[hits[0]][:len(lines[hits[0]]) - len(lines[hits[0]].lstrip())]
    lines[hits[0]] = indent + line
    p.write_text("\n".join(lines))


def master_parts(master):
    """The shipped master's pieces: tile colour, disc (colour, radius) and the note path."""
    bg, mark = parse_master(master)
    disc = re.search(r'<circle id="disc" cx="50" cy="50" r="([0-9.]+)" fill="(#[0-9A-Fa-f]{6})"/>', mark)
    note = re.search(r'<path id="note" fill="(#[0-9A-Fa-f]{6})" d="([^"]+)"/>', mark)
    assert disc and note, "master: expected <circle id=disc> and <path id=note> in <g id=mark>"
    return bg, disc.group(2), float(disc.group(1)), note.group(1), note.group(2)


def mark_only(master, size):
    """The mark without its tile (disc + note), scaled so the disc fills `size`: launch screen."""
    _, mark = parse_master(master)
    _, _, r, _, _ = master_parts(master)
    k = size / (2 * r)
    return svg(size, size, f'<g transform="translate({-(50 - r) * k:.3f} {-(50 - r) * k:.3f}) scale({k:.5f})">{mark}</g>')


def tray(master, size, pad):
    """Menu-bar template: the disc in black with the note knocked out (only alpha matters)."""
    _, _, r, _, d = master_parts(master)
    k = (size - 2 * pad) / (2 * r)
    o = pad - (50 - r) * k
    return svg(size, size, f'<defs><mask id="m"><rect width="100" height="100" fill="#fff"/>'
                           f'<path fill="#000" d="{d}"/></mask></defs>'
                           f'<g transform="translate({o:.3f} {o:.3f}) scale({k:.5f})">'
                           f'<circle cx="50" cy="50" r="{r:g}" fill="#000" mask="url(#m)"/></g>')


def ship():
    master = MASTER.read_text()
    bg, disc, rad, ink, d = master_parts(master)
    check_colours("master", [disc])
    icons = ROOT / "src-tauri/icons"
    cat = ROOT / "ios/Encore/Encore/Resources/Assets.xcassets"
    app = cat / "AppIcon.appiconset"
    for old in ("AppIcon-1024-dark.png", "AppIcon-1024-tinted.png"):
        (app / old).unlink(missing_ok=True)
    rounded = svg(100, 100, framed(master, 0, 0, 100))
    r = Renderer()
    try:
        mac = mac_icon(master)
        for name, sz in [("32x32", 32), ("64x64", 64), ("128x128", 128), ("128x128@2x", 256), ("icon", 512)]:
            r.add(mac, icons / f"{name}.png", sz, "shadow")
        iconset = r.tmp / "icon.iconset"
        for base in (16, 32, 128, 256, 512):
            r.add(mac, iconset / f"icon_{base}x{base}.png", base, "shadow")
            r.add(mac, iconset / f"icon_{base}x{base}@2x.png", base * 2, "shadow")
        for sz in (30, 44, 71, 89, 107, 142, 150, 284, 310):
            r.add(rounded, icons / f"Square{sz}x{sz}Logo.png", sz)
        r.add(rounded, icons / "StoreLogo.png", 50)
        ico = [16, 24, 32, 48, 64, 256]
        for sz in ico:
            r.add(rounded, r.tmp / f"ico{sz}.png", sz)
        r.add(tray(master, 44, 3), icons / "tray-template.png", 44)
        r.add(ios_icon(master), app / "AppIcon-1024.png", 1024, "opaque")
        r.add(mark_only(master, 360), cat / f"{LAUNCH}.imageset/{LAUNCH}@3x.png", 360)
        r.run()
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icons / "icon.icns")], check=True)
        write_ico(icons / "icon.ico", [(sz, (r.tmp / f"ico{sz}.png").read_bytes()) for sz in ico])
    finally:
        r.close()
    (app / "Contents.json").write_text(json.dumps({"images": [
        {"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}}) + "\n")
    (cat / f"{LAUNCH}.imageset/Contents.json").write_text(json.dumps({"images": [
        {"filename": f"{LAUNCH}@3x.png", "idiom": "universal", "scale": "3x"}],
        "info": {"author": "xcode", "version": 1}}) + "\n")
    # The note for SwiftUI (template; SpotlessMark draws the disc and tints this the note colour).
    gs = cat / "SpotlessGlyph.imageset"
    gs.mkdir(exist_ok=True)
    (gs / "spotless-glyph.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">'
        f'<path fill="#000000" d="{d}"/></svg>\n')
    (gs / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "spotless-glyph.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"}}) + "\n")
    (ROOT / "ui/src/lib/assets/favicon.svg").write_text(rounded + "\n")
    # Inlined copies, regenerated from the master. In-app and on covers the mark is drawn without
    # its black tile (the disc and note): the tile is the platform's icon shape, like the padding.
    k = 48 / (2 * rad)
    o = 28 - (50 - rad) * k
    cover = (f'<g transform="translate({o:.2f} {o:.2f}) scale({k:.4f})"><circle cx="50" cy="50" r="{rad:g}" '
             f'fill="{disc}"/><path fill="{ink}" d="{d}"/></g>')
    sync_line("ui/src/lib/kit/Logo.svelte", "export const MARK_D =", f"export const MARK_D = '{d}'; // gen-brand")
    sync_line("ui/src/lib/kit/Logo.svelte", "export const MARK_DISC =", f"export const MARK_DISC = '{disc}'; // gen-brand")
    sync_line("ui/src/lib/kit/Logo.svelte", "export const MARK_INK =", f"export const MARK_INK = '{ink}'; // gen-brand")
    sync_line("ui/src/lib/kit/Logo.svelte", "export const MARK_R =", f"export const MARK_R = {rad:g}; // gen-brand")
    sync_line("crates/core/src/smart/mfy.rs", "const SPOTLESS_MARK:", f'const SPOTLESS_MARK: &str = r##"{cover}"##; // gen-brand')
    sync_line("ui/src/lib/devmock/smart2.ts", "const MARK =", f"const MARK = '{cover}'; // gen-brand")
    sync_line("ios/Encore/Encore/Screens/MadeForYou.swift", "static let disc =", f'static let disc = Color(hex: "{disc}") // gen-brand')
    sync_line("ios/Encore/Encore/Screens/MadeForYou.swift", "static let ink =", f'static let ink = Color(hex: "{ink}") // gen-brand')
    sync_line("ios/Encore/Encore/Screens/MadeForYou.swift", "static let discShare:", f'static let discShare: CGFloat = {2 * rad / 100:g} // gen-brand')
    print("shipped", MASTER.relative_to(ROOT))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "ship": ship()
    else: sys.exit(__doc__)
