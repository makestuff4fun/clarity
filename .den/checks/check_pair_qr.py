"""Acceptance: `clarity device pair NAME --qr / --qr-file` (task pair-server, 2026-11-20).

Brian: "We should make it so clarity can pair. Open link or scan code etc." The app's scan
screen reads this code, so the check proves the code carries EXACTLY the printed link. It does
not trust the encoder: it parses the half-block drawing, the PNG pixels and the SVG path back
into modules and decodes them with its own QR reader below (format bits, unmasking, block
de-interleave, Reed-Solomon ECC recomputed, byte-mode data).

    python3 .den/checks/check_pair_qr.py

segno: until .den/server-requirements.txt pins it, server/.venv has no segno; this check then
installs segno==1.6.6 once into ~/.local/share/clarity/check-segno-1.6.6 (uv, else pip) and puts
it on PYTHONPATH for bin/clarity only. Once the pin is in the venv that step is skipped.
"""
import json
import os
import re
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from server_common import CLARITY, PY, ROOT, fail, need, need_server_package, tmpdir  # noqa: E402

SEGNO_PIN = "segno==1.6.6"

# ---------------------------------------------------------------- a small QR reader (model 2, v1-10)
ECC_PER_BLOCK = {"L": [0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18], "M": [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26],
                 "Q": [0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24], "H": [0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28]}
NUM_BLOCKS = {"L": [0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4], "M": [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5],
              "Q": [0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8], "H": [0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8]}
ECL_BITS = {"L": 1, "M": 0, "Q": 3, "H": 2}
MASKS = [lambda x, y: (x + y) % 2 == 0, lambda x, y: y % 2 == 0, lambda x, y: x % 3 == 0,
         lambda x, y: (x + y) % 3 == 0, lambda x, y: (x // 3 + y // 2) % 2 == 0,
         lambda x, y: x * y % 2 + x * y % 3 == 0, lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
         lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0]


def format_bits(ecl, mask):
    data = ECL_BITS[ecl] << 3 | mask
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    return (data << 10 | rem) ^ 0x5412


def align_positions(ver, size):
    if ver == 1:
        return []
    n = ver // 7 + 2
    step = (ver * 4 + n * 2 + 1) // (n * 2 - 2) * 2
    return [6] + sorted(size - 7 - i * step for i in range(n - 1))


def raw_modules(ver):
    r = (16 * ver + 128) * ver + 64
    if ver >= 2:
        n = ver // 7 + 2
        r -= (25 * n - 10) * n - 55
        if ver >= 7:
            r -= 36
    return r


def gf_mul(a, b):
    z = 0
    for i in range(7, -1, -1):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((b >> i) & 1) * a
    return z & 0xFF


def rs_remainder(data, degree):
    div = [0] * (degree - 1) + [1]
    root = 1
    for _ in range(degree):
        for j in range(degree):
            div[j] = gf_mul(div[j], root)
            if j + 1 < degree:
                div[j] ^= div[j + 1]
        root = gf_mul(root, 0x02)
    res = [0] * degree
    for b in data:
        f = b ^ res.pop(0)
        res.append(0)
        for i in range(degree):
            res[i] ^= gf_mul(div[i], f)
    return res


def decode(m):
    """m[y][x] True = dark, no quiet zone. Returns the byte-mode payload as str, or fail()s."""
    size = len(m)
    need(size >= 21 and all(len(r) == size for r in m) and (size - 17) % 4 == 0, f"not a QR matrix: {size} modules")
    ver = (size - 17) // 4
    need(ver <= 10, f"version {ver} > 10: link far longer than expected")
    fn = [[False] * size for _ in range(size)]

    def mark(x0, y0, w, h):
        for y in range(max(0, y0), min(size, y0 + h)):
            for x in range(max(0, x0), min(size, x0 + w)):
                fn[y][x] = True
    for i in range(size):
        fn[6][i] = fn[i][6] = True
    mark(0, 0, 9, 9), mark(size - 8, 0, 8, 9), mark(0, size - 8, 9, 8)
    al = align_positions(ver, size)
    for a in al:
        for b in al:
            if not ((a == 6 and b == 6) or (a == 6 and b == al[-1]) or (a == al[-1] and b == 6)):
                mark(a - 2, b - 2, 5, 5)
    if ver >= 7:
        mark(size - 11, 0, 3, 6), mark(0, size - 11, 6, 3)
    # finder patterns, so a garbled drawing cannot pass by luck
    for fx, fy in ((0, 0), (size - 7, 0), (0, size - 7)):
        for dy in range(7):
            for dx in range(7):
                ring = max(abs(dx - 3), abs(dy - 3))
                need(m[fy + dy][fx + dx] == (ring != 2), f"finder pattern at ({fx},{fy}) is wrong")
    need(m[size - 8][8], "dark module missing")
    got = 0
    pos = [(8, i) for i in range(6)] + [(8, 7), (8, 8), (7, 8)] + [(14 - i, 8) for i in range(9, 15)]
    for i, (x, y) in enumerate(pos):
        got |= m[y][x] << i
    match = [(e, k) for e in "LMQH" for k in range(8) if format_bits(e, k) == got]
    need(match, f"format bits {got:015b} match no level/mask")
    ecl, mask = match[0]
    bits = []
    right = size - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(size):
            for j in range(2):
                x = right - j
                y = size - 1 - vert if ((right + 1) & 2) == 0 else vert
                if not fn[y][x]:
                    bits.append(m[y][x] ^ MASKS[mask](x, y))
        right -= 2
    raw = raw_modules(ver) // 8
    need(len(bits) >= raw * 8, f"{len(bits)} data modules, need {raw * 8}")
    cw = [int("".join(str(int(b)) for b in bits[i * 8:i * 8 + 8]), 2) for i in range(raw)]
    nb, ecc = NUM_BLOCKS[ecl][ver], ECC_PER_BLOCK[ecl][ver]
    short_len = raw // nb
    n_short = nb - raw % nb
    blocks = [[] for _ in range(nb)]
    k = 0
    for i in range(short_len + 1):
        for j in range(nb):
            if i != short_len - ecc or j >= n_short:
                blocks[j].append(cw[k])
                k += 1
    data = []
    for j, b in enumerate(blocks):
        dlen = len(b) - ecc
        need(rs_remainder(b[:dlen], ecc) == b[dlen:], f"Reed-Solomon ECC of block {j} is wrong")
        data += b[:dlen]
    s = "".join(f"{b:08b}" for b in data)
    out, p = b"", 0
    while p + 4 <= len(s):
        mode = s[p:p + 4]
        p += 4
        if mode == "0000":
            break
        need(mode == "0100", f"segment mode {mode}: expected byte mode (0100)")
        cl = 8 if ver <= 9 else 16
        n = int(s[p:p + cl], 2)
        p += cl
        out += bytes(int(s[p + 8 * i:p + 8 * i + 8], 2) for i in range(n))
        p += 8 * n
    return out.decode("utf-8")


def trim(grid):
    """Crop a dark-is-True grid to the bounding box of its dark modules (drop the quiet zone)."""
    ys = [y for y, r in enumerate(grid) if any(r)]
    xs = [x for r in grid for x, v in enumerate(r) if v]
    need(ys and xs, "no dark modules at all")
    return [r[min(xs):max(xs) + 1] for r in grid[min(ys):max(ys) + 1]]


# ---------------------------------------------------------------- the three renderings, back to modules
HALF = {"█": (False, False), "▀": (False, True), "▄": (True, False), " ": (True, True)}


def from_terminal(text):
    lines = [ln for ln in text.splitlines()]
    block = []
    for ln in lines:
        if ln and set(ln) <= set(HALF) and "█" in ln:
            block.append(ln)
        elif block:
            break
    need(len(block) >= 11, f"no half-block QR drawing found in:\n{text}")
    need(len({len(ln) for ln in block}) == 1, "QR drawing lines differ in width")
    need(all(ln.startswith("██") and ln.endswith("██") for ln in block), "QR drawing has no light quiet zone")
    grid = []
    for ln in block:
        grid.append([HALF[c][0] for c in ln])
        grid.append([HALF[c][1] for c in ln])
    return trim(grid), block


def from_png(path):
    d = Path(path).read_bytes()
    need(d[:8] == b"\x89PNG\r\n\x1a\n", f"{path} is not a PNG")
    p, idat, plte, hdr = 8, b"", None, None
    while p < len(d):
        n, typ = struct.unpack(">I4s", d[p:p + 8])
        body = d[p + 8:p + 8 + n]
        if typ == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", body)
        elif typ == b"PLTE":
            plte = [body[i:i + 3] for i in range(0, n, 3)]
        elif typ == b"IDAT":
            idat += body
        p += 12 + n
    w, h, depth, ctype, _, _, interlace = hdr
    need(interlace == 0 and ctype in (0, 2, 3) and depth in (1, 2, 4, 8), f"unexpected PNG format {hdr}")
    ch = 3 if ctype == 2 else 1
    bpp = max(1, ch * depth // 8)
    stride = (w * ch * depth + 7) // 8
    raw = zlib.decompress(idat)
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line

    def dark(x, y):
        r = rows[y]
        if depth == 8:
            v = r[x * ch:x * ch + ch]
        else:
            per = 8 // depth
            v = [(r[x // per] >> (8 - depth * (x % per + 1))) & ((1 << depth) - 1)]
            if ctype == 0:
                v = [v[0] * 255 // ((1 << depth) - 1)]
        if ctype == 3:
            v = plte[v[0]]
        return sum(v) / len(v) < 128
    px = [[dark(x, y) for x in range(w)] for y in range(h)]
    box = trim(px)
    unit = 0
    while unit < len(box[0]) and box[0][unit]:
        unit += 1
    need(unit % 7 == 0, f"PNG finder row is {unit}px, not a multiple of 7")
    unit //= 7
    n = len(box) // unit
    need(len(box) == n * unit == len(box[0]), "PNG code is not a whole number of square modules")
    return [[box[y * unit + unit // 2][x * unit + unit // 2] for x in range(n)] for y in range(n)]


def from_svg(path):
    root = ET.parse(path).getroot()
    need(root.tag.endswith("svg"), f"{path} root is <{root.tag}>, not <svg>")
    paths = [e for e in root.iter() if e.tag.endswith("path") and e.get("d")]
    need(paths, f"{path} has no <path>")
    cells, x, y = set(), 0.0, 0.0
    for el in paths:
        toks = re.findall(r"[MmHhVvZz]|-?\d*\.?\d+", el.get("d"))
        need(set(t for t in toks if t.isalpha()) <= set("Mmh"), f"unexpected SVG path commands in {path}")
        i = 0
        while i < len(toks):
            c = toks[i]
            if c in "Mm":
                dx, dy = float(toks[i + 1]), float(toks[i + 2])
                x, y = (dx, dy) if c == "M" else (x + dx, y + dy)
                i += 3
            else:
                dx = float(toks[i + 1])
                for k in range(int(round(dx))):
                    cells.add((int(x) + k, int(y)))
                x += dx
                i += 2
    n = max(max(a for a, _ in cells), max(b for _, b in cells)) + 1
    return trim([[(xx, yy) in cells for xx in range(n)] for yy in range(n)])


# ---------------------------------------------------------------- run it
def venv_has_segno():
    return subprocess.run([PY, "-c", "import segno"], capture_output=True).returncode == 0


def segno_path():
    if venv_has_segno():
        return None
    t = Path.home() / ".local/share/clarity" / f"check-{SEGNO_PIN.replace('==', '-')}"
    if not (t / "segno" / "__init__.py").is_file():
        t.parent.mkdir(parents=True, exist_ok=True)
        cmds = [["uv", "pip", "install", "-q", "--target", str(t), SEGNO_PIN],
                [PY, "-m", "pip", "install", "-q", "--target", str(t), SEGNO_PIN]]
        for c in cmds:
            try:
                if subprocess.run(c, capture_output=True, timeout=300).returncode == 0:
                    break
            except (OSError, subprocess.TimeoutExpired):
                pass
        need((t / "segno" / "__init__.py").is_file(), f"could not install {SEGNO_PIN} (add it to .den/server-requirements.txt)")
    return str(t)


need_server_package()
need(SEGNO_PIN in (ROOT / "server" / "requirements.txt").read_text().split(), f"server/requirements.txt must pin {SEGNO_PIN}")
home = tmpdir("clarity-pairqr-")
env = {**os.environ, "CLARITY_DB": str(home / "clarity.db"), "CLARITY_DATA": str(home / "data")}
env.pop("PYTHONPATH", None)
extra = segno_path()
if extra:
    env["PYTHONPATH"] = extra
    print(f"note: server/.venv has no segno; using {extra} until .den/server-requirements.txt pins {SEGNO_PIN}")


def cli(*args, rc=0):
    r = subprocess.run([CLARITY, *args], cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
    need(r.returncode == rc, f"bin/clarity {' '.join(args)}: rc {r.returncode}, want {rc}\n{r.stdout}\n{r.stderr}")
    return r


def printed_link(out):
    links = re.findall(r"^\s*(clarity://provision\?code=\S+)\s*$", out, re.M)
    need(len(links) == 1, f"expected one printed clarity:// link, got {links}:\n{out}")
    return links[0]


# 1. without --qr: exactly the old output, no drawing
plain = cli("device", "pair", "plain-phone").stdout
need(not set(plain) & set("█▀▄"), f"pair without --qr drew something:\n{plain}")
need(re.fullmatch(r"pairing code for plain-phone \(valid 10 minutes, once\):\n  [a-z ]+\nlink:\n  clarity://provision\?code=\S+\n",
                  plain), f"pair without --qr changed its output:\n{plain}")

# 2. --qr: the drawing decodes to exactly the printed link
out = cli("device", "pair", "find-n6", "--qr").stdout
link = printed_link(out)
code = re.search(r"once\):\n  (.+)\n", out).group(1)
need(link.endswith("=" + code.replace(" ", "%20")), f"printed link {link} does not carry the printed code")
m, block = from_terminal(out)
got = decode(m)
need(got == link, f"terminal QR decodes to {got!r}, printed link is {link!r}")
need(len(block[0]) <= 80 and len(block) <= 40, f"terminal QR is {len(block[0])}x{len(block)} chars: too big for a normal terminal")
print(f"--qr: {len(m)}x{len(m)} modules drawn in {len(block[0])}x{len(block)} chars, decodes to the printed link")

# 3. --json --qr --qr-file x.png: pure JSON on stdout, PNG decodes to the JSON's link
png = home / "pair.png"
j = cli("device", "pair", "tab", "--json", "--qr", "--qr-file", str(png)).stdout
try:
    obj = json.loads(j)
except json.JSONDecodeError:
    fail(f"--json --qr must print pure JSON, got:\n{j}")
need(set(obj) == {"code", "link", "expires"} and j.count("\n") == 1, f"--json output changed: {j!r}")
need(png.is_file() and png.stat().st_size > 0, "--qr-file PNG not written")
need(png.stat().st_mode & 0o077 == 0, f"{png} is readable by others (it holds a live code)")
got = decode(from_png(png))
need(got == obj["link"], f"PNG decodes to {got!r}, JSON link is {obj['link']!r}")
print("--json --qr --qr-file .png: stdout is pure JSON; PNG decodes to its link")

# 4. --qr-file x.svg
svg = home / "pair.svg"
out = cli("device", "pair", "laptop", "--qr-file", str(svg)).stdout
link = printed_link(out)
need(not set(out) & set("█▀▄"), "--qr-file alone must not draw in the terminal")
need(svg.is_file(), "--qr-file SVG not written")
got = decode(from_svg(svg))
need(got == link, f"SVG decodes to {got!r}, printed link is {link!r}")
print("--qr-file .svg: SVG decodes to the printed link")

# 5. a bad --qr-file fails before any code is minted
before = subprocess.run([PY, "-c", "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('select count(*) from pair_codes').fetchone()[0])",
                         env["CLARITY_DB"]], capture_output=True, text=True).stdout
cli("device", "pair", "x", "--qr-file", str(home / "pair.jpg"), rc=2)
cli("device", "pair", "x", "--qr-file", str(home / "no-such-dir" / "p.png"), rc=2)
after = subprocess.run([PY, "-c", "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('select count(*) from pair_codes').fetchone()[0])",
                        env["CLARITY_DB"]], capture_output=True, text=True).stdout
need(before == after and before.strip().isdigit(), f"a rejected --qr-file still minted a code ({before!r} -> {after!r})")
print("bad --qr-file: rc 2, no code minted")
print("check_pair_qr: OK")
