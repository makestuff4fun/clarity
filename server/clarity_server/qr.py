"""QR codes for `clarity device pair --qr / --qr-file` (segno: pure Python, no other deps).

The terminal drawing packs two module rows into one line with unicode half-blocks, so a
~41-module code is ~25 lines tall and a phone camera reads it at normal terminal size.
Ink is drawn where the code is LIGHT (the dark modules are left as the terminal's own
background), which is right on the usual dark terminal; on a tty the colours are also forced
(bright white on black) so a light-themed terminal shows the same, un-inverted code.
"""
import os
import sys

BORDER = 4  # the quiet zone the QR spec asks for, in modules
_CHARS = {(False, False): "█", (False, True): "▀", (True, False): "▄", (True, True): " "}


def _make(data: str):
    try:
        import segno
    except ImportError:  # the venv predates the pin; say so instead of a traceback
        raise RuntimeError("QR output needs segno (server/requirements.txt: segno==1.6.6)") from None
    return segno.make(data, error="m", micro=False)


def matrix(data: str) -> list[list[bool]]:
    """The code's modules, True = dark, without the quiet zone."""
    return [[bool(v) for v in row] for row in _make(data).matrix]


def terminal(data: str, color: bool | None = None) -> str:
    """The code as half-block text (lines joined by newlines, no trailing newline)."""
    m = matrix(data)
    n = len(m) + 2 * BORDER
    grid = [[False] * n for _ in range(BORDER)]
    grid += [[False] * BORDER + row + [False] * BORDER for row in m]
    grid += [[False] * n for _ in range(BORDER)]
    if len(grid) % 2:
        grid.append([False] * n)
    lines = ["".join(_CHARS[(top[x], bot[x])] for x in range(n)) for top, bot in zip(grid[0::2], grid[1::2])]
    if color is None:
        color = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
    if color:
        lines = [f"\x1b[97;40m{ln}\x1b[0m" for ln in lines]
    return "\n".join(lines)


def kind_for(path: str) -> str:
    ext = os.path.splitext(path)[1].lower()
    if ext not in (".png", ".svg"):
        raise ValueError(f"--qr-file must end in .png or .svg, not {path!r}")
    return ext[1:]


def preflight(path: str | None) -> None:
    """Raise (ValueError / RuntimeError) if --qr / --qr-file cannot succeed, before a code exists."""
    if path:
        kind_for(path)
        parent = os.path.dirname(os.path.abspath(path))
        if not os.path.isdir(parent):
            raise ValueError(f"--qr-file: no such directory {parent}")
    _make("clarity://")


def save(data: str, path: str) -> None:
    """Write the code as PNG or SVG (by extension), readable only by its owner: it holds a live code."""
    kind = kind_for(path)
    q = _make(data)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        q.save(f, kind=kind, scale=8, border=BORDER)
