#!/usr/bin/env python3
"""Regenerates the images the README shows, in docs/images/readme/.

This is a design tool, not part of the build: it needs macOS with Google
Chrome (text, gradients, layout), Pillow (cropping and the JPEGs), and Xcode's
ictool (the app icon). The
wordmark is the app's own Montserrat Black at the brand's 0.18em tracking, and
the surfaces use the deep-blue tokens in Sources/SillMenuBar/MacDesign.swift.

usage: python3 design/readme/build.py
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image, ImageChops, ImageDraw
except ImportError:
    sys.exit("Pillow is needed: python3 -m pip install Pillow")

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs/images/readme"
FONT = ROOT / "iOSClient/Montserrat-900.ttf"
ICON_DOC = ROOT / "Packaging/DuoAppIcon.icon"
CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
ICTOOL = Path("/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool")

# The wordmark's V, outlined from Montserrat Black: the app icon's watermark.
V = "M422.9 1000.0 L0.0 0.0 L362.9 0.0 L707.1 844.3 L491.4 844.3 L845.7 0.0 L1177.1 0.0 L754.3 1000.0 Z"

# The Bilibili mark from Simple Icons (CC0).
BILIBILI = (
    "M17.813 4.653h.854c1.51.054 2.769.578 3.773 1.574 1.004.995 1.524 2.249 1.56 3.76v7.36c-.036 1.51"
    "-.556 2.769-1.56 3.773s-2.262 1.524-3.773 1.56H5.333c-1.51-.036-2.769-.556-3.773-1.56S.036 18.858"
    " 0 17.347v-7.36c.036-1.511.556-2.765 1.56-3.76 1.004-.996 2.262-1.52 3.773-1.574h.774l-1.174-1.12"
    "a1.234 1.234 0 0 1-.373-.906c0-.356.124-.658.373-.907l.027-.027c.267-.249.573-.373.92-.373.347 0"
    " .653.124.92.373L9.653 4.44c.071.071.134.142.187.213h4.267a.836.836 0 0 1 .16-.213l2.853-2.747"
    "c.267-.249.573-.373.92-.373.347 0 .662.151.929.4.267.249.391.551.391.907 0 .355-.124.657-.373.906z"
    "M5.333 7.24c-.746.018-1.373.276-1.88.773-.506.498-.769 1.13-.786 1.894v7.52c.017.764.28 1.395.786"
    " 1.893.507.498 1.134.756 1.88.773h13.334c.746-.017 1.373-.275 1.88-.773.506-.498.769-1.129.786"
    "-1.893v-7.52c-.017-.765-.28-1.396-.786-1.894-.507-.497-1.134-.755-1.88-.773zM8 11.107c.373 0 .684"
    ".124.933.373.25.249.383.569.4.96v1.173c-.017.391-.15.711-.4.96-.249.25-.56.374-.933.374s-.684-.125"
    "-.933-.374c-.25-.249-.383-.569-.4-.96V12.44c0-.373.129-.689.386-.947.258-.257.574-.386.947-.386zm8"
    " 0c.373 0 .684.124.933.373.25.249.383.569.4.96v1.173c-.017.391-.15.711-.4.96-.249.25-.56.374-.933"
    ".374s-.684-.125-.933-.374c-.25-.249-.383-.569-.4-.96V12.44c.017-.391.15-.711.4-.96.249-.249.56-.373"
    ".933-.373Z"
)


def require_environment():
    missing = [str(p) for p in (CHROME, FONT, ICTOOL) if not p.exists()]
    if missing:
        sys.exit("Missing: " + ", ".join(missing) + " (macOS 27 with Xcode and Chrome)")


class Work:
    """One scratch directory for a run's intermediate pages and renders."""

    def __init__(self):
        self.dir = Path(tempfile.mkdtemp(prefix="duo-readme-"))
        self.icon = self.dir / "icon.png"
        subprocess.run([ICTOOL, str(ICON_DOC), "--export-image", "--output-file", str(self.icon),
                        "--platform", "macOS", "--rendition", "Default", "--width", "1024",
                        "--height", "1024", "--scale", "1", "--design-generation", "27"],
                       check=True, capture_output=True)

    def render(self, name, body, css, width, height):
        """Screenshots one page with headless Chrome, at 2x."""
        page = self.dir / f"{name}.html"
        page.write_text(f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family:'Montserrat'; src:url('{FONT.as_uri()}'); font-weight:900; font-display:block }}
* {{ margin:0; padding:0; box-sizing:border-box }}
html, body {{ width:{width}px; height:{height}px; overflow:hidden; background:transparent }}
{css}</style></head><body>{body}</body></html>""")
        png = self.dir / f"{name}.png"
        command = [str(CHROME), "--headless=new", "--disable-gpu", "--hide-scrollbars",
                   "--allow-file-access-from-files", "--default-background-color=00000000",
                   f"--user-data-dir={self.dir / ('profile-' + name)}", "--no-first-run",
                   f"--screenshot={png}", f"--window-size={width},{height}",
                   "--force-device-scale-factor=2", str(page)]
        # Chrome's teardown watchdog sometimes reports failure after writing the file, so the
        # screenshot on disk is what counts; a missing or unreadable one gets one retry.
        for attempt in range(2):
            try:
                subprocess.run(command, capture_output=True, timeout=120)
            except subprocess.TimeoutExpired:
                pass
            try:
                return Image.open(png).convert("RGBA")
            except (OSError, ValueError):
                if attempt:
                    raise
        raise AssertionError("unreachable")

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


# --------------------------------------------------------------------- hero

HERO_CSS = """
body {{ font-family:'PingFang SC',-apple-system,sans-serif; display:flex; align-items:center;
  justify-content:center }}
.card {{ position:relative; overflow:hidden; width:1200px; height:330px; display:flex;
  flex-direction:column; align-items:center; justify-content:center; {card} {ring} }}
.vmark {{ position:absolute; right:-60px; bottom:-230px; width:480px; {vmark} }}
.lockup {{ position:relative; display:flex; align-items:center; gap:34px }}
.icon {{ width:112px; height:112px; display:block; {icon} }}
.wordmark {{ font-family:'Montserrat'; font-weight:900; font-size:84px; line-height:1;
  letter-spacing:.18em; text-indent:.18em; white-space:nowrap; {wordmark} }}
.rule {{ position:relative; width:300px; height:1px; margin:26px 0 18px; {rule} }}
.diamond {{ position:absolute; left:50%; top:-2.5px; width:6px; height:6px;
  transform:translateX(-50%) rotate(45deg); {diamond} }}
.eyebrow {{ position:relative; font-family:'Montserrat'; font-weight:900; font-size:15px;
  letter-spacing:.44em; text-indent:.44em; {eyebrow} }}
"""

HERO_THEMES = {
    "dark": {
        "card": """background:
          radial-gradient(760px 330px at 46% -20%, rgba(35,167,255,.30), transparent 72%),
          radial-gradient(600px 340px at 102% 138%, rgba(43,214,255,.11), transparent 72%),
          linear-gradient(168deg, #0A1524 0%, #060D17 50%, #04080F 100%);""",
        "vmark": "fill:#FFFFFF; opacity:.035",
        "icon": "filter:drop-shadow(0 18px 40px rgba(0,0,0,.62))",
        "ring": "box-shadow:inset 0 0 0 1px rgba(105,180,255,.13)",
        "wordmark": """background:linear-gradient(180deg,#FFFFFF 0%,#EAF7FF 44%,#9FD4F5 100%);
          -webkit-background-clip:text; background-clip:text; color:transparent;
          filter:drop-shadow(0 8px 28px rgba(43,214,255,.16))""",
        "rule": "background:linear-gradient(90deg,rgba(105,180,255,.75),rgba(105,180,255,0))",
        "diamond": "background:#2BD6FF; box-shadow:0 0 9px rgba(43,214,255,.8)",
        "eyebrow": "color:#5E7896",
    },
    "light": {
        "card": """background:
          radial-gradient(760px 330px at 46% -20%, rgba(11,99,198,.14), transparent 72%),
          radial-gradient(600px 340px at 102% 138%, rgba(43,214,255,.16), transparent 72%),
          linear-gradient(168deg, #FFFFFF 0%, #F6FAFF 50%, #E5EEF9 100%);""",
        "vmark": "fill:#0B63C6; opacity:.035",
        "icon": "filter:drop-shadow(0 10px 22px rgba(12,26,42,.16))",
        "ring": "box-shadow:inset 0 0 0 1px rgba(11,99,198,.12)",
        "wordmark": """background:linear-gradient(180deg,#12294A 0%,#0C1A2A 58%,#1B4F86 100%);
          -webkit-background-clip:text; background-clip:text; color:transparent;
          filter:drop-shadow(0 6px 20px rgba(11,99,198,.12))""",
        "rule": "background:linear-gradient(90deg,rgba(11,99,198,.50),rgba(11,99,198,0))",
        "diamond": "background:#0B63C6; box-shadow:0 0 7px rgba(11,99,198,.4)",
        "eyebrow": "color:#7C93AD",
    },
}

HERO_BODY = """<div class="card">
  <svg class="vmark" viewBox="0 0 1177 1000"><path d="{v}"/></svg>
  <div class="lockup">
    <img class="icon" src="{icon}">
    <div class="wordmark">VISIONTEC</div>
  </div>
  <div class="rule"><span class="diamond"></span></div>
  <div class="eyebrow">MAC REMOTE DESKTOP</div>
</div>"""


# ------------------------------------------------------- the Bilibili button

CTA_CSS = """
body { font-family:'PingFang SC',-apple-system,sans-serif; display:flex; align-items:center;
  justify-content:center }
.btn { display:inline-flex; align-items:center; gap:20px; padding:24px 40px 24px 28px;
  border-radius:26px; background:linear-gradient(135deg,#0B63C6 0%,#1B8BDD 54%,#2BD6FF 132%);
  box-shadow:0 18px 40px -14px rgba(27,139,221,.75), inset 0 0 0 1px rgba(255,255,255,.34),
  inset 0 1px 0 rgba(255,255,255,.30) }
.plate { display:flex; align-items:center; justify-content:center; width:64px; height:64px;
  border-radius:19px; background:rgba(255,255,255,.18);
  box-shadow:inset 0 0 0 1px rgba(255,255,255,.34) }
.text { display:flex; flex-direction:column; gap:6px }
.label { font-size:27px; font-weight:600; color:#fff; letter-spacing:.02em; line-height:1 }
.sub { font-size:15px; color:rgba(255,255,255,.86); letter-spacing:.06em;
  font-family:'Montserrat','PingFang SC',sans-serif; font-weight:900 }
.chev { color:rgba(255,255,255,.72) }
"""


def cta(work):
    body = f"""<div class="btn">
  <span class="plate"><svg viewBox="0 0 24 24" width="33" height="33"><path fill="#fff"
    d="{BILIBILI}"/></svg></span>
  <span class="text"><span class="label">Visiontec 主页 · 哔哩哔哩</span>
  <span class="sub">SPACE.BILIBILI.COM/18564290</span></span>
  <svg class="chev" viewBox="0 0 24 24" width="21" height="21" fill="none" stroke="currentColor"
    stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 5l7 7-7 7"/></svg>
</div>"""
    return work.render("cta-bilibili", body, CTA_CSS, 560, 132)


# -------------------------------------------------------------- screenshots

def screenshot(source, width):
    """Crops a product render to its content, rounds it, and rules a hairline edge."""
    im = Image.open(ROOT / "docs/images" / f"{source}.png").convert("RGB")
    white = Image.new("RGB", im.size, (255, 255, 255))
    box = ImageChops.difference(im, white).convert("L").point(lambda v: 255 if v > 8 else 0).getbbox()
    im = im.crop((max(0, box[0] - 10), max(0, box[1] - 10),
                  min(im.width, box[2] + 10), min(im.height, box[3] + 10)))
    im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS).convert("RGBA")

    radius = 22
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, im.width - 1, im.height - 1), radius, fill=255)
    im.putalpha(mask)
    ImageDraw.Draw(im).rounded_rectangle((1, 1, im.width - 2, im.height - 2), radius,
                                        outline=(208, 218, 232, 255), width=2)
    return im


# ------------------------------------------------------------------- badges

BADGE_CSS = """
body {{ font-family:'Montserrat','PingFang SC',sans-serif; display:flex; align-items:center;
  justify-content:center }}
.badge {{ display:inline-flex; align-items:stretch; height:46px; border-radius:11px;
  overflow:hidden; {ring} }}
.key {{ display:flex; align-items:center; padding:0 16px 0 17px; background:#16233A;
  color:#8FA7C2; font-size:15px; font-weight:600; letter-spacing:.10em }}
.val {{ display:flex; align-items:center; padding:0 17px 0 16px; {val} }}
.val span {{ font-size:15px; font-weight:600; letter-spacing:.04em; color:#FFFFFF }}
"""

BADGES = [
    ("macOS", "27+", "#0B63C6", "#7FE3DC"),
    ("iOS · iPadOS", "27.1+", "#0B63C6", "#7FE3DC"),
    ("Swift", "Apple native", "#0D5C8C", "#8FD9F6"),
    ("许可证", "Apache-2.0", "#0E4D66", "#9BE8E0"),
]


def badge(work, index, key, value, background):
    css = BADGE_CSS.format(ring="box-shadow:inset 0 0 0 1px rgba(255,255,255,.14)",
                           val=f"background:{background}")
    body = f"""<div class="badge"><span class="key">{key}</span>
  <span class="val"><span>{value}</span></span></div>"""
    return work.render(f"badge-{index}", body, css, 320, 60)


def save_jpeg(im, name, quality=88, width=None, matte=(255, 255, 255)):
    """JPEG has no alpha: transparent corners would come out black, so they get a matte."""
    if width and im.width > width:
        im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
    if im.mode == "RGBA":
        flat = Image.new("RGB", im.size, matte)
        flat.paste(im, mask=im.getchannel("A"))
        im = flat
    path = OUT / f"{name}.jpg"
    im.convert("RGB").save(path, "JPEG", quality=quality, subsampling=0, optimize=True,
                           progressive=True)
    return path


def save_png(im, name, trim=False):
    if trim:
        box = im.getchannel("A").point(lambda v: 255 if v > 4 else 0).getbbox()
        if box:
            im = im.crop(box)
    path = OUT / f"{name}.png"
    im.save(path, optimize=True)
    return path


def main():
    require_environment()
    OUT.mkdir(parents=True, exist_ok=True)
    work = Work()
    try:
        for theme in ("dark", "light"):
            im = work.render(f"hero-{theme}", HERO_BODY.format(v=V, icon=work.icon.as_uri()),
                             HERO_CSS.format(**HERO_THEMES[theme]), 1200, 330)
            print(save_jpeg(im, f"hero-{theme}", 92, width=1600))

        print(save_png(cta(work), "cta-bilibili"))

        for index, (key, value, background, _) in enumerate(BADGES):
            save_png(badge(work, index, key, value, background), f"badge-{index}", trim=True)

        for name, source, width in (("shot-overview", "duomac-overview", 1200),
                                    ("shot-controls", "duomac-controls", 760),
                                    ("shot-desktop", "duomac-desktop", 760)):
            print(save_jpeg(screenshot(source, width), name, 90))
    finally:
        work.close()


if __name__ == "__main__":
    main()
