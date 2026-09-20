#!/usr/bin/env python3
"""Publish a Clarity art-review page so Brian can actually see it.

THE PAGE CONTENT BELOW IS HISTORICAL - it builds the 2026-09 dev-vs-schnell icon
A/B, which is decided and shipped. What is worth keeping is the MECHANISM, which
was expensive to work out and lived only in a session scratchpad until now.
Re-point SRC/DST and rewrite main()'s sections for a new review.

WHY A PUBLISHED PAGE AT ALL
Brian is on blue, not red. He cannot see anything rendered on red, and files sent
through a session's own file-attachment channel never reached him - that failure
was silent and cost a day. The route is: write into /srv/www/images/<dir>/ and it
is live. Never run your own web server.

    https://images.hanquest.com:62280/clarity-icons/   (TLS, basic auth `bairui`)

The port cannot be dropped: 80/443 are blocked inbound by the ISP, so Caddy
serves the fleet's viewer hosts on 62280.

WE WRITE A SUBDIRECTORY, NEVER THE SLOT ROOT, AND NEVER WITH --delete.
That slot's own publish command is `rsync -a --delete out/review-web/
/srv/www/images/`, which makes that directory the single source of truth for the
whole slot - a --delete from us would erase every live page the images session
has there. The converse hazard is real too and is flagged on the page itself:
THEIR next --delete publish erases this directory.

A 401 IS NOT PROOF THE PAGE IS SERVED. Caddy's basic_auth fires BEFORE the file
lookup, so a path that exists and one that does not both answer 401. What can be
verified from red is narrower and worth doing: the files are on disk under the
served root, every <img src> resolves, and the comment sink answers 200 on
127.0.0.1:8790. The authenticated 200 is Brian's browser, not ours.

EVERY EVALUATED ITEM GETS ITS OWN COMMENT BOX - a fleet standard and Brian's own
ruling (hanquest-images/docs/inline-feedback-standard.md). Never one shared box.
Slugs are SEMANTIC (`clarity-ab-<subject>`), never ordinal, because the request
file that lands in requests/ days later is named from the slug. Sharper form of
the rule, learned since: use separate PAGES when two teams' work would otherwise
share one, or a batched ask gets one verdict pulled toward the worse item.

Comments route to the `images` slot because comment-server.py has no `clarity`
slot, so Brian's notes land in hanquest-images/requests/. Adding one is a the-den
change that needs his ask. Read the sink directly rather than trusting a relay -
relays have arrived both incomplete (2 of 4) and mis-attributed:

    curl -s --noproxy '*' \
      "http://127.0.0.1:8790/_api/comments?slot=images&path=decisions/<slug>"

Each size is rendered as its own LANCZOS image rather than scaled by the browser,
because the point is judging what the app actually draws at 24-48px.
"""
import os, shutil, sys
from PIL import Image

sys.path.insert(0, "/home/bairui/projects/the-den/briefings")
from feedback_snippet import FEEDBACK_CSS, ans_box, ans_script

SRC = "/srv/outputs/clarity_icons"
DST = "/srv/www/images/clarity-icons"
IMG = os.path.join(DST, "img")

AB = ["investment", "celebration", "code", "decrease", "subscription", "insurance-shield",
      "sofa", "suitcase", "folder", "tax-form", "cheque", "calendar", "newspaper",
      "gears", "wifi", "dna", "plane", "smartphone"]
# Called by eye, stated as a judgement rather than a measurement.
MISS = {"outline": {"celebration", "decrease", "subscription", "wifi"},
        "outline_schnell": {"celebration", "decrease", "subscription", "wifi", "dna", "folder"}}
CUTFAIL = {"outline_schnell": {"smartphone", "wifi"}}

BAKEOFF = ["groceries", "car", "coffee", "house", "gift", "dog", "bank", "money", "phone", "plane"]
ARMS = ["flat", "outline", "sticker", "clay", "iso", "paper"]


def emit(src, name, sizes=(128, 48, 36, 24)):
    """Write each size as its own LANCZOS render. Letting the browser scale a
    128px png down to 24 shows the browser's filter, not what the app draws."""
    im = Image.open(src).convert("RGBA")
    out = {}
    for s in sizes:
        f = f"{name}_{s}.png"
        im.resize((s, s), Image.LANCZOS).save(os.path.join(IMG, f))
        out[s] = f"img/{f}"
    return out


def main():
    os.makedirs(IMG, exist_ok=True)
    P = []
    A = P.append

    A('<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    A("<title>Clarity icons — dev vs schnell</title><style>")
    A(""":root{--paper:#f5eede;--paper2:#efe6d2;--ink:#1c1712;--ink2:#4a4034;--line:#d8cbb0;
      --accent:#9a3b1f;--accent2:#1f5054;--serif:Georgia,serif;--mono:ui-monospace,monospace}
    *{box-sizing:border-box}
    body{margin:0;background:var(--paper);color:var(--ink);font-family:var(--serif);line-height:1.5}
    .wrap{max-width:1180px;margin:0 auto;padding:28px 20px 80px}
    h1{font-size:26px;margin:0 0 4px} h2{font-size:19px;margin:38px 0 10px;
      border-bottom:1px solid var(--line);padding-bottom:5px}
    .sub{color:var(--ink2);margin:0 0 20px;font-size:15px}
    .warn{background:#f7e3d8;border-left:3px solid var(--accent);padding:10px 13px;
      margin:0 0 20px;font-size:14px}
    table.n{border-collapse:collapse;font-family:var(--mono);font-size:13px;margin:0 0 8px}
    table.n td,table.n th{padding:4px 14px 4px 0;text-align:right;border-bottom:1px solid var(--line)}
    table.n th:first-child,table.n td:first-child{text-align:left}
    .win{color:var(--accent2);font-weight:bold}
    .item{border-top:1px solid var(--line);padding:16px 0;display:grid;
      grid-template-columns:150px 1fr;gap:18px;align-items:start}
    .nm{font-family:var(--mono);font-size:13px;padding-top:6px}
    .nm .tag{display:block;font-size:10px;letter-spacing:.05em;margin-top:5px}
    .bad{color:var(--accent)} .cut{color:#8a6d1f}
    .pair{display:flex;gap:26px;flex-wrap:wrap;margin:0 0 10px}
    .arm{background:var(--paper2);border:1px solid var(--line);border-radius:4px;padding:9px 11px}
    .arm h4{margin:0 0 7px;font-family:var(--mono);font-size:11px;letter-spacing:.05em;
      text-transform:uppercase;color:var(--ink2);font-weight:normal}
    .row{display:flex;align-items:flex-end;gap:12px}
    .row img{background:#fff;border-radius:3px}
    .zoom{image-rendering:pixelated;width:96px;height:96px;border:1px dashed var(--line)}
    .cap{font-family:var(--mono);font-size:9px;color:var(--ink2);text-align:center;display:block;margin-top:3px}
    .grid{display:grid;grid-template-columns:repeat(11,auto);gap:6px;align-items:center;
      overflow-x:auto;font-family:var(--mono);font-size:10px}
    .grid img{background:#fff}""")
    A(FEEDBACK_CSS)
    A("</style><div class=wrap>")

    A("<h1>Clarity category icons — which model renders the set</h1>")
    A("<p class=sub>Style is settled: the <b>outline</b> arm you picked. This page decides "
      "the model that renders all 479. Both arms below use <b>identical prompts and seed "
      "72000</b>; the only differences are the checkpoint, steps (24 vs 4), and that schnell "
      "has no guidance module for FluxGuidance to feed.</p>")

    A('<div class=warn><b>This page lives in the images slot and is not permanent.</b> '
      'That slot is published with <code>rsync -a --delete out/review-web/ /srv/www/images/</code>, '
      'so the next images publish will erase this directory. Comments route to the '
      '<code>images</code> slot because there is no <code>clarity</code> slot in '
      "<code>comment-server.py</code> — your notes will land in hanquest-images/requests/.</div>")

    A("<h2>STOP &mdash; a third approach, and I think it is the right one</h2>")
    A("<p class=sub>You said both arms are not amazing and this feels like the same mistakes as "
      "before. I agree, and I think the fault is not the model. <b>An icon set is a system, and "
      "diffusion cannot hold a system.</b> Every round so far has treated 479 icons as 479 "
      "independent illustration problems, when what makes a set look like a set is a handful of "
      "shared invariants \u2014 one stroke weight, one grid, one level of detail, one optical "
      "size. Nothing in a diffusion sampler carries an invariant from icon 7 to icon 200.</p>")
    A("<p class=sub>Measured on this batch alone: six style arms collapsed into two families; "
      "\u201ca bold line drawing\u201d returned a pencil sketch about a third of the time; the "
      "same prompt gave 0.5% ink on dev and 11.9% on schnell; <code>decrease</code> drew a "
      "<i>rising</i> arrow; <code>wifi</code> drew a blob. Those are not prompt bugs to grind "
      "out. They are what sampling independently 479 times looks like.</p>")
    A("<p class=sub>Below are real icons from <b>Tabler</b> (MIT, 5,130 icons, drawn on a 24px "
      "grid at one stroke weight), tinted per category the way the app already colours its "
      "chips. Same subjects as the diffusion arms. Look at the bottom row \u2014 48, 36, 24px "
      "\u2014 and compare it to anything above.</p>")
    A('<div style="background:#fff;border:1px solid var(--line);border-radius:5px;padding:16px;'
      'overflow-x:auto;margin:0 0 8px"><div style="display:flex;gap:14px">')
    TB = ["building-bank","calendar","car","coffee","device-mobile","dna","dog","folder",
          "gift","home","plane","receipt","shield","shopping-bag","sofa","wifi"]
    for n in TB:
        A('<div style="text-align:center">')
        A(f'<img src="img/tb_{n}_128.png" width=96 height=96><br>')
        for sz in (48,36,24):
            A(f'<img src="img/tb_{n}_{sz}.png" width={sz} height={sz} style="vertical-align:bottom">')
        A(f'<span class=cap>{n}</span></div>')
    A("</div></div>")
    A("<p class=sub><b>Coverage, measured against all 479 of your icon names</b> (using the tags "
      "already in <code>iconObjects.dart</code>): Tabler exact-matches 128, matches another 184 "
      "through tags \u2014 <b>65% mapped automatically</b> \u2014 82 more are probable and need "
      "an eye, and <b>85 have no candidate at all</b> (bagel, bakery, bathtub, bear, boxing-glove, "
      "burrito, canoe, cheque, aquarium\u2026). That 65% is a floor, not a ceiling: Tabler ships "
      "its own tags in each SVG and I matched on names only. Those last ~85 are a drawing job in "
      "the same 24px/2px system, which is a bounded, finite piece of work \u2014 unlike 479 "
      "samples that never converge.</p>")
    A("<p class=sub><b>The trade you would be making:</b> you lose colourful illustration and "
      "gain a coherent system. Colour moves from inside the icon to the chip behind it, which is "
      "how Monzo, Revolut and YNAB do it. If that is the wrong feel for Clarity, say so and the "
      "answer changes \u2014 but then the honest path is a designer, not another checkpoint.</p>")
    A(ans_box("clarity-approach-vector", "is this the right direction? \u2026"))

    A("<h2>The numbers</h2>")
    A("<p class=sub>Measured on the 16 of 18 that <i>both</i> arms cut cleanly. schnell's two "
      "page-keeping cutouts are excluded from both arms, or the metric measures the cutout "
      "failure instead of the model.</p>")
    A("<table class=n><tr><th>metric</th><th>dev</th><th>schnell</th></tr>")
    for lab, d, s, who in [("near-black ink pixels %", "6.8", "11.9", "s"),
                           ("RMS contrast at 24px", "48.7", "56.3", "s"),
                           ("frame filled %", "39.4", "44.8", "s"),
                           ("render time / image", "10.4s", "4.1s", "s"),
                           ("cutout failures (of 18)", "0", "2", "d"),
                           ("concept correct — by eye", "14/18", "12/18", "d")]:
        A(f"<tr><td>{lab}</td><td class=\"{'win' if who=='d' else ''}\">{d}</td>"
          f"<td class=\"{'win' if who=='s' else ''}\">{s}</td></tr>")
    A("</table>")
    A("<p class=sub><b>Recommendation: schnell.</b> It wins the acceptance criterion — "
      "legibility at the 24px the app actually draws these — and is 2.5&times; faster "
      "(1.1h vs 2.8h for 479 at two seeds). Its concept deficit is narrower than 14-vs-12 "
      "looks: four of its six misses are shared with dev, and two of those "
      "(<code>decrease</code>, <code>wifi</code>) are facts that get drawn procedurally on any "
      "model. Real losses are <code>dna</code>, <code>folder</code> and two white-on-white "
      "cutouts. It also removes the FLUX.1-dev non-commercial licence question, which matters "
      "for a public GPL-3.0 repo.</p>")

    # Added after Brian's first pass. His only criticism of dev was "not enough
    # contrast on the left, no outline" — the one axis the metrics put schnell
    # ahead on. dev is the arm that responds to prompt and guidance, so that gap
    # is a candidate for fixing rather than a property to accept.
    A("<h2>NEW &mdash; dev with a heavier stroke</h2>")
    A("<p class=sub>You said of <code>subscription</code>: <i>\u201cNot enough contrast on the "
      "left, no outline.\u201d</i> Left is dev on every row. So here is dev asked for the stroke "
      "explicitly. It lifts near-black ink from <b>0.5% to 10.5%</b> across these six \u2014 "
      "schnell sits at 10.8%, so dev can be given the outline it was missing. Judge whether it "
      "keeps dev\u2019s coherence while doing it.</p>")
    for n in ["cheque", "insurance-shield", "sofa", "subscription", "folder", "dna"]:
        A("<div class=item><div class=nm>" + n + "</div><div><div class=pair>")
        for arm, lab in (("outline", "dev &mdash; as you saw it"),
                         ("outline2", "dev + HEAVY STROKE &mdash; new"),
                         ("outline_schnell", "schnell")):
            src = f"{SRC}/cut/{arm}/{n}_72000.png"
            if not os.path.exists(src):
                continue
            u = emit(src, f"hv_{arm}_{n}")
            A(f"<div class=arm><h4>{lab}</h4><div class=row>")
            A(f'<span><img src="{u[128]}" width=128 height=128><span class=cap>128</span></span>')
            for sz in (48, 24):
                A(f'<span><img src="{u[sz]}" width={sz} height={sz}><span class=cap>{sz}</span></span>')
            A(f'<span><img class=zoom src="{u[24]}"><span class=cap>24 &times;4</span></span>')
            A("</div></div>")
        A("</div>")
        A(ans_box(f"clarity-heavy-{n}", "does the heavy stroke fix it?\u2026"))
        A("</div></div>")

    A("<h2>The 18, side by side</h2>")
    A("<p class=sub>Each size is its own LANCZOS render, not a browser downscale. The dashed "
      "square is the 24px version blown up 4&times; with no smoothing — what is actually "
      "there at chip size. Red = wrong concept (my judgement). Amber = the knockout kept the "
      "page.</p>")

    for n in AB:
        A("<div class=item>")
        tags = ""
        for arm, lab in (("outline", "dev"), ("outline_schnell", "schnell")):
            if n in MISS[arm]:
                tags += f'<span class="tag bad">{lab}: off-concept</span>'
            if n in CUTFAIL.get(arm, ()):
                tags += f'<span class="tag cut">{lab}: cutout kept page</span>'
        A(f"<div class=nm>{n}{tags}</div><div>")
        A("<div class=pair>")
        for arm, lab in (("outline", "dev &middot; 24 steps &middot; guidance 2.8"),
                         ("outline_schnell", "schnell &middot; 4 steps &middot; no guidance")):
            src = f"{SRC}/cut/{arm}/{n}_72000.png"
            if not os.path.exists(src):
                continue
            u = emit(src, f"ab_{arm}_{n}")
            A(f"<div class=arm><h4>{lab}</h4><div class=row>")
            A(f'<span><img src="{u[128]}" width=128 height=128><span class=cap>128</span></span>')
            for s in (48, 36, 24):
                A(f'<span><img src="{u[s]}" width={s} height={s}><span class=cap>{s}</span></span>')
            A(f'<span><img class=zoom src="{u[24]}"><span class=cap>24 &times;4</span></span>')
            A("</div></div>")
        A("</div>")
        A(ans_box(f"clarity-ab-{n}", "which arm, and why — or what to fix…"))
        A("</div></div>")

    A("<h2>For reference — the six-arm bake-off you picked from</h2>")
    A("<p class=sub>Rendered on dev, seed 71000. This is the choice already made "
      "(<b>outline</b>); it is here so the pick can be revisited against the real "
      "subjects rather than from memory.</p>")
    A("<div class=grid>")
    A("<div></div>" + "".join(f"<div>{b}</div>" for b in BAKEOFF))
    for arm in ARMS:
        A(f"<div>{arm}</div>")
        for b in BAKEOFF:
            src = f"{SRC}/cut/{arm}/{b}_71000.png"
            if os.path.exists(src):
                u = emit(src, f"bo_{arm}_{b}", sizes=(96,))
                A(f'<div><img src="{u[96]}" width=96 height=96></div>')
            else:
                A("<div></div>")
    A("</div>")
    for arm in ARMS:
        A(f"<div class=item><div class=nm>{arm}</div><div>"
          + ans_box(f"clarity-arm-{arm}", f"note on the {arm} arm…") + "</div></div>")

    A(ans_script("images"))
    A("</div>")

    with open(os.path.join(DST, "index.html"), "w") as f:
        f.write("\n".join(P))
    n = len(os.listdir(IMG))
    print(f"wrote {DST}/index.html  ({n} images)")


if __name__ == "__main__":
    main()
