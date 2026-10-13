#!/usr/bin/env python3
"""Writes Discord's icons, and a plugin's where a feature is the plugin's, as
custom SF Symbols into Glyphs.xcassets.

    scripts/make-discord-glyphs.py

Each glyph is Discord's own 24-unit outline (the `d` of its icon component in
the web client's bundle). Arcs and relative commands are resolved to absolute
M/L/C/Z, the grid is scaled to Discord's proportion against its "#" (22.5 units
of ink to 20, measured against the SF `number` that stands for that "#" in the
app) and centred on the cap-height midline, as SF Symbols are, on Apple's
symbol template: the Small row only, which the system scales for the rest.

actool needs the template's Notes (it reads "Template v.5.0" from them) and its
guides, so both are written in full. `DiscordGlyphTests` checks the result.
"""
import math, os, re

# The outlines, by symbol name: Discord's ThreadIcon (163328), ThreadLockIcon
# (425557) and ThreadPlusIcon; Vencord's AnonymiseFileNames toggle, which is
# Material's incognito and incognito-off on the same 24-unit grid.
GLYPHS = {
    "discord.thread": [
        "M12 2.81a1 1 0 0 1 0-1.41l.36-.36a1 1 0 0 1 1.41 0l9.2 9.2a1 1 0 0 1 0 1.4l-.7.7a1 1 0 0 1-1.3.13l-9.54-6.72a1 1 0 0 1-.08-1.58l1-1L12 2.8ZM12 21.2a1 1 0 0 1 0 1.41l-.35.35a1 1 0 0 1-1.41 0l-9.2-9.19a1 1 0 0 1 0-1.41l.7-.7a1 1 0 0 1 1.3-.12l9.54 6.72a1 1 0 0 1 .07 1.58l-1 1 .35.36ZM15.66 16.8a1 1 0 0 1-1.38.28l-8.49-5.66A1 1 0 1 1 6.9 9.76l8.49 5.65a1 1 0 0 1 .27 1.39ZM17.1 14.25a1 1 0 1 0 1.11-1.66L9.73 6.93a1 1 0 0 0-1.11 1.66l8.49 5.66Z",
    ],
    "discord.thread.lock": [
        "M19 15a2.5 2.5 0 0 1 2.5 2.5v.5h.5a1 1 0 0 1 1 1v4a1 1 0 0 1-1 1h-6a1 1 0 0 1-1-1v-4a1 1 0 0 1 1-1h.5v-.5A2.5 2.5 0 0 1 19 15Zm0 1.5a1 1 0 0 0-1 1v.5h2v-.5a1 1 0 0 0-1-1Z",
        "M1.73 11.67a1 1 0 0 1 1.3-.13l9.55 6.72a1 1 0 0 1 .07 1.58l-1 1 .35.36a1 1 0 0 1 0 1.4l-.35.36a1 1 0 0 1-1.41 0l-9.2-9.19a1 1 0 0 1 0-1.41l.7-.7ZM5.51 10.03a1 1 0 0 1 1.39-.27l7.82 5.21c.22.15.29.44.18.68l-.1.24a1.45 1.45 0 0 1-.57.7.56.56 0 0 1-.64.03l-7.8-5.2a1 1 0 0 1-.28-1.39ZM8.34 7.2a1 1 0 0 1 1.39-.27l8.48 5.66c.24.15.08.46-.2.52-.46.1-.9.28-1.29.51-.17.1-.4.1-.57 0L8.62 8.58a1 1 0 0 1-.28-1.38ZM12.36 1.04a1 1 0 0 1 1.41 0l9.2 9.2a1 1 0 0 1 0 1.4l-.7.7a1 1 0 0 1-1.3.13l-9.54-6.72a1 1 0 0 1-.08-1.58l1-1L12 2.8a1 1 0 0 1 0-1.41l.36-.36Z",
    ],
    "discord.thread.plus": [
        "M19 14a1 1 0 0 1 1 1v3h3a1 1 0 1 1 0 2h-3v3a1 1 0 0 1-2 0v-3h-3a1 1 0 0 1 0-2h3v-3a1 1 0 0 1 1-1ZM12 19c0-.22.03-.44.08-.66a.56.56 0 0 0-.21-.58l-8.84-6.22a1 1 0 0 0-1.3.13l-.69.69a1 1 0 0 0 0 1.41l9.2 9.2a1 1 0 0 0 1.4 0l.36-.36a1 1 0 0 0 0-1.41l-.35-.36.37-.37a.56.56 0 0 0 .12-.56A3 3 0 0 1 12 19ZM15 16h.16c.33 0 .56-.32.3-.53a.98.98 0 0 0-.07-.06L6.9 9.76a1 1 0 1 0-1.1 1.66l7.3 4.88c.17.1.39.1.56.02.4-.2.86-.32 1.34-.32ZM15.82 13.39c.25.17.6.07.77-.17.12-.17.26-.32.42-.46.29-.26.32-.76 0-.98L9.73 6.93a1 1 0 0 0-1.11 1.66l7.2 4.8ZM12 2.81a1 1 0 0 1 0-1.41l.36-.36a1 1 0 0 1 1.41 0l9.2 9.2a1 1 0 0 1 0 1.4l-.7.7a1 1 0 0 1-1.3.13l-9.54-6.72a1 1 0 0 1-.08-1.58l1-1L12 2.8Z",
    ],
    "vencord.incognito": [
        "M17.06 13C15.2 13 13.64 14.33 13.24 16.1C12.29 15.69 11.42 15.8 10.76 16.09C10.35 14.31 8.79 13 6.94 13C4.77 13 3 14.79 3 17C3 19.21 4.77 21 6.94 21C9 21 10.68 19.38 10.84 17.32C11.18 17.08 12.07 16.63 13.16 17.34C13.34 19.39 15 21 17.06 21C19.23 21 21 19.21 21 17C21 14.79 19.23 13 17.06 13M6.94 19.86C5.38 19.86 4.13 18.58 4.13 17S5.39 14.14 6.94 14.14C8.5 14.14 9.75 15.42 9.75 17S8.5 19.86 6.94 19.86M17.06 19.86C15.5 19.86 14.25 18.58 14.25 17S15.5 14.14 17.06 14.14C18.62 14.14 19.88 15.42 19.88 17S18.61 19.86 17.06 19.86M22 10.5H2V12H22V10.5M15.53 2.63C15.31 2.14 14.75 1.88 14.22 2.05L12 2.79L9.77 2.05L9.72 2.04C9.19 1.89 8.63 2.17 8.43 2.68L6 9H18L15.56 2.68L15.53 2.63Z",
    ],
    "vencord.incognito.slash": [
        "M22.11 21.46L2.39 1.73L1.11 3L6.31 8.2L6 9H7.11L8.61 10.5H2V12H10.11L13.5 15.37C13.38 15.61 13.3 15.85 13.24 16.1C12.29 15.69 11.41 15.8 10.76 16.09C10.35 14.31 8.79 13 6.94 13C4.77 13 3 14.79 3 17C3 19.21 4.77 21 6.94 21C9 21 10.68 19.38 10.84 17.32C11.18 17.08 12.07 16.63 13.16 17.34C13.34 19.39 15 21 17.06 21C17.66 21 18.22 20.86 18.72 20.61L20.84 22.73L22.11 21.46M6.94 19.86C5.38 19.86 4.13 18.58 4.13 17C4.13 15.42 5.39 14.14 6.94 14.14C8.5 14.14 9.75 15.42 9.75 17C9.75 18.58 8.5 19.86 6.94 19.86M17.06 19.86C15.5 19.86 14.25 18.58 14.25 17C14.25 16.74 14.29 16.5 14.36 16.25L17.84 19.73C17.59 19.81 17.34 19.86 17.06 19.86M22 12H15.2L13.7 10.5H22V12M17.06 13C19.23 13 21 14.79 21 17C21 17.25 20.97 17.5 20.93 17.73L19.84 16.64C19.68 15.34 18.66 14.32 17.38 14.17L16.29 13.09C16.54 13.03 16.8 13 17.06 13M12.2 9L7.72 4.5L8.43 2.68C8.63 2.17 9.19 1.89 9.72 2.04L9.77 2.05L12 2.79L14.22 2.05C14.75 1.88 15.32 2.14 15.54 2.63L15.56 2.68L18 9H12.2Z",
    ],
}

# Drawn mirrored, as the plugin draws its struck-through incognito
# (`transform: scale(-1,1)`).
MIRRORED = {"vencord.incognito.slash"}

SCALE = 3.684        # template units per grid unit, Small row
INK_SIDEBEARING = 9.4
CAP_MIDLINE = -(696.0 - 625.541) / 2
WEIGHTS = {"Ultralight": 515.649, "Regular": 1403.58, "Black": 2884.57}

PARAMS = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0}
NUMBER = re.compile(r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")


def commands(d):
    """(command, numbers) pairs; arc flags may be packed without separators."""
    out, cmd, args, i = [], None, [], 0
    while i < len(d):
        c = d[i]
        if c.isalpha():
            if cmd:
                out.append((cmd, args))
            cmd, args, i = c, [], i + 1
        elif c in " ,\t\n":
            i += 1
        elif cmd in ("A", "a") and len(args) % 7 in (3, 4):
            args.append(float(c))
            i += 1
        else:
            m = NUMBER.match(d, i)
            args.append(float(m.group(0)))
            i = m.end()
    if cmd:
        out.append((cmd, args))
    return out


def arc(x1, y1, rx, ry, phi, large, sweep, x2, y2):
    """An elliptical arc as cubics, at most a quarter turn each (SVG F.6)."""
    if (x1, y1) == (x2, y2):
        return []
    if rx == 0 or ry == 0:
        return [("L", (x2, y2))]
    rx, ry = abs(rx), abs(ry)
    p = math.radians(phi)
    cp, sp = math.cos(p), math.sin(p)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
    lam = x1p**2 / rx**2 + y1p**2 / ry**2
    if lam > 1:
        rx, ry = rx * math.sqrt(lam), ry * math.sqrt(lam)
    num = rx**2 * ry**2 - rx**2 * y1p**2 - ry**2 * x1p**2
    den = rx**2 * y1p**2 + ry**2 * x1p**2
    co = math.sqrt(max(0, num / den)) if den else 0
    if large == sweep:
        co = -co
    cxp, cyp = co * rx * y1p / ry, -co * ry * x1p / rx
    cx, cy = cp * cxp - sp * cyp + (x1 + x2) / 2, sp * cxp + cp * cyp + (y1 + y2) / 2
    angle = lambda ux, uy, vx, vy: math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    t = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dt > 0:
        dt -= 2 * math.pi
    elif sweep and dt < 0:
        dt += 2 * math.pi
    n = max(1, math.ceil(abs(dt) / (math.pi / 2) - 1e-9))
    step = dt / n
    k = 4 / 3 * math.tan(step / 4)
    point = lambda a: (cp * rx * math.cos(a) - sp * ry * math.sin(a) + cx, sp * rx * math.cos(a) + cp * ry * math.sin(a) + cy)
    tangent = lambda a: (-cp * rx * math.sin(a) - sp * ry * math.cos(a), -sp * rx * math.sin(a) + cp * ry * math.cos(a))
    out = []
    for _ in range(n):
        p0, p3, t0, t3 = point(t), point(t + step), tangent(t), tangent(t + step)
        out.append(("C", (p0[0] + k * t0[0], p0[1] + k * t0[1], p3[0] - k * t3[0], p3[1] - k * t3[1], p3[0], p3[1])))
        t += step
    return out


def absolute(d):
    """Absolute M/L/C/Z segments for any path."""
    out, cx, cy, sx, sy, lastc, lastq = [], 0.0, 0.0, 0.0, 0.0, None, None
    for cmd, args in commands(d):
        rel, C = cmd.islower(), cmd.upper()
        if C == "Z":
            out.append(("Z", ()))
            cx, cy, lastc, lastq = sx, sy, None, None
            continue
        n = PARAMS[C]
        for j in range(0, len(args), n):
            a = args[j:j + n]
            if C in "ML":
                x, y = a[0] + (cx if rel else 0), a[1] + (cy if rel else 0)
                if C == "M" and j == 0:
                    out.append(("M", (x, y)))
                    sx, sy = x, y
                else:
                    out.append(("L", (x, y)))
                cx, cy, lastc, lastq = x, y, None, None
            elif C == "H":
                cx = a[0] + (cx if rel else 0)
                out.append(("L", (cx, cy)))
                lastc = lastq = None
            elif C == "V":
                cy = a[0] + (cy if rel else 0)
                out.append(("L", (cx, cy)))
                lastc = lastq = None
            elif C in "CS":
                if C == "C":
                    x1, y1, x2, y2, x, y = a
                    if rel:
                        x1, y1 = x1 + cx, y1 + cy
                else:
                    x2, y2, x, y = a
                    x1, y1 = (2 * cx - lastc[0], 2 * cy - lastc[1]) if lastc else (cx, cy)
                if rel:
                    x2, y2, x, y = x2 + cx, y2 + cy, x + cx, y + cy
                out.append(("C", (x1, y1, x2, y2, x, y)))
                lastc, cx, cy, lastq = (x2, y2), x, y, None
            elif C in "QT":
                if C == "Q":
                    qx, qy, x, y = a
                    if rel:
                        qx, qy = qx + cx, qy + cy
                else:
                    x, y = a
                    qx, qy = (2 * cx - lastq[0], 2 * cy - lastq[1]) if lastq else (cx, cy)
                if rel:
                    x, y = x + cx, y + cy
                out.append(("C", (cx + 2 / 3 * (qx - cx), cy + 2 / 3 * (qy - cy), x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y), x, y)))
                lastq, cx, cy, lastc = (qx, qy), x, y, None
            elif C == "A":
                rx, ry, phi, large, sweep, x, y = a
                if rel:
                    x, y = x + cx, y + cy
                out.extend(arc(cx, cy, rx, ry, phi, int(large), int(sweep), x, y))
                cx, cy, lastc, lastq = x, y, None, None
    return out


def emit(segments, transform):
    def f(v):
        s = ("%.3f" % v).rstrip("0").rstrip(".")
        return "0" if s in ("-0", "") else s
    parts = []
    for c, a in segments:
        if c == "Z":
            parts.append("Z")
        else:
            points = [transform(a[i], a[i + 1]) for i in range(0, len(a), 2)]
            parts.append(c + " ".join(f(x) + " " + f(y) for x, y in points))
    return " ".join(parts)


GUIDES = """<g id="Guides">
  <g id="H-reference" style="fill:#27AAE1;stroke:none;" transform="matrix(1 0 0 1 339 696)">
   <path d="M0.993654 0L3.63775 0L29.3281-67.1323L30.0303-67.1323L30.0303-70.459L28.1226-70.459ZM11.6885-24.4799L46.9815-24.4799L46.2315-26.7285L12.4385-26.7285ZM55.1196 0L57.7637 0L30.6382-70.459L29.4326-70.459L29.4326-67.1323Z"/>
  </g>
  <line id="Baseline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="696" y2="696"/>
  <line id="Capline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="625.541" y2="625.541"/>
  <g id="H-reference" style="fill:#27AAE1;stroke:none;" transform="matrix(1 0 0 1 339 1126)">
   <path d="M0.993654 0L3.63775 0L29.3281-67.1323L30.0303-67.1323L30.0303-70.459L28.1226-70.459ZM11.6885-24.4799L46.9815-24.4799L46.2315-26.7285L12.4385-26.7285ZM55.1196 0L57.7637 0L30.6382-70.459L29.4326-70.459L29.4326-67.1323Z"/>
  </g>
  <line id="Baseline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1126" y2="1126"/>
  <line id="Capline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1055.54" y2="1055.54"/>
  <g id="H-reference" style="fill:#27AAE1;stroke:none;" transform="matrix(1 0 0 1 339 1556)">
   <path d="M0.993654 0L3.63775 0L29.3281-67.1323L30.0303-67.1323L30.0303-70.459L28.1226-70.459ZM11.6885-24.4799L46.9815-24.4799L46.2315-26.7285L12.4385-26.7285ZM55.1196 0L57.7637 0L30.6382-70.459L29.4326-70.459L29.4326-67.1323Z"/>
  </g>
  <line id="Baseline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1556" y2="1556"/>
  <line id="Capline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
  <line id="left-margin-Ultralight-S" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="515.649" x2="515.649" y1="600.785" y2="720.121"/>
  <line id="right-margin-Ultralight-S" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="603.773" x2="603.773" y1="600.785" y2="720.121"/>
  <line id="left-margin-Regular-S" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="1403.58" x2="1403.58" y1="600.785" y2="720.121"/>
  <line id="right-margin-Regular-S" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="1496.11" x2="1496.11" y1="600.785" y2="720.121"/>
  <line id="left-margin-Black-S" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="2884.57" x2="2884.57" y1="600.785" y2="720.121"/>
  <line id="right-margin-Black-S" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="2982.23" x2="2982.23" y1="600.785" y2="720.121"/>
 </g>"""


def template(name, paths):
    grid = 24 * SCALE
    sidebearing = INK_SIDEBEARING - SCALE * 0.75
    advance = 2 * sidebearing + grid
    flip = (lambda x: 24 - x) if name in MIRRORED else (lambda x: x)
    place = lambda x, y: (sidebearing + SCALE * flip(x), CAP_MIDLINE - grid / 2 + SCALE * y)
    d = " ".join(emit(absolute(p), place) for p in paths)
    guides = re.sub(
        r'(<line id="right-margin-(\w+)-S"[^>]*?)x1="[\d.]+" x2="[\d.]+"',
        lambda m: '%sx1="%.3f" x2="%.3f"' % (m.group(1), WEIGHTS[m.group(2)] + advance, WEIGHTS[m.group(2)] + advance),
        GUIDES,
    )
    symbols = "\n  ".join(
        '<g id="%s-S" transform="matrix(1 0 0 1 %s 696)">\n'
        '   <path class="monochrome-0 multicolor-0:tintColor hierarchical-0:primary SFSymbolsPreviewWireframe" d="%s"/>\n'
        "  </g>" % (weight, x, d)
        for weight, x in WEIGHTS.items()
    )
    text = 'style="stroke:none;fill:black;font-family:sans-serif;font-size:13;'
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE svg\nPUBLIC "-//W3C//DTD SVG 1.1//EN"\n       "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">\n'
        '<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">\n'
        ' <!--glyph: "", point size: 100.0, font version: "19.2d2e1", template writer version: "128"-->\n'
        " <style>.monochrome-0 {-sfsymbols-motion-group:0}\n.multicolor-0:tintColor {-sfsymbols-motion-group:0}\n"
        ".hierarchical-0:primary {-sfsymbols-motion-group:0}\n"
        ".SFSymbolsPreviewWireframe {fill:none;opacity:1.0;stroke:black;stroke-width:0.5}\n</style>\n"
        ' <g id="Notes">\n'
        '  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>\n'
        '  <text id="template-version" %stext-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.5.0</text>\n'
        '  <text id="descriptive-name" %stext-anchor:end;" transform="matrix(1 0 0 1 3036 1969)">%s</text>\n'
        '  <text %s" transform="matrix(1 0 0 1 263 726)">Small</text>\n'
        '  <text %s" transform="matrix(1 0 0 1 263 1156)">Medium</text>\n'
        '  <text %s" transform="matrix(1 0 0 1 263 1586)">Large</text>\n'
        " </g>\n %s\n <g id=\"Symbols\">\n  %s\n </g>\n</svg>\n"
    ) % (text, text, name, text, text, text, guides, symbols)


def main():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "Wingcord", "Resources", "Glyphs.xcassets")
    os.makedirs(root, exist_ok=True)
    info = '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'
    with open(os.path.join(root, "Contents.json"), "w") as f:
        f.write(info)
    for name, paths in GLYPHS.items():
        folder = os.path.join(root, name + ".symbolset")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, name + ".svg"), "w") as f:
            f.write(template(name, paths))
        with open(os.path.join(folder, "Contents.json"), "w") as f:
            f.write('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n  "symbols" : [\n    {\n'
                    '      "filename" : "%s.svg",\n      "idiom" : "universal"\n    }\n  ]\n}\n' % name)
    print("wrote", len(GLYPHS), "symbols to", os.path.normpath(root))


if __name__ == "__main__":
    main()
