# CONTEXT — working state

Durable project facts live in `README.md`. This file is the live working
context: what is in flight, what was decided, and what is waiting on Brian.

Last updated 2026-09-06.

---

## The job

Two things Brian asked for: **a modern readable font**, and **a new set of
icons**.

**Font — DONE**, commit `34be351`. Inter is the default; Pixelify Sans, its two
TTFs and its bundled OFL are gone. See README, *Look and feel*.
⚠️ **Not build-verified. Flutter is not installed on red**, so nothing Dart can
be compiled or analysed on this box — `flutter analyze` and `flutter test` need
another machine. Say that rather than implying the change was checked.

**Icons — IN PROGRESS, currently held.** See below.

---

## Where the icon work stands

Renders are produced by the **images** pipeline on red (ComfyUI + RTX 5090).
The renderer is `tools/hd2d/clarity_icons.py` in the **hanquest-images** repo
(commits `5a6bada9`, `057af2f8`, `13c32f57` on `red-dev`).

⚠️ **Brian objected to me committing into hanquest-images** — it is the images
session's active branch and we were interleaving commits. Whether those three
commits stay, are reverted, or the generator moves to `budget/tool/` beside
`process_pixel_art.py` is **an open decision of his, still unanswered.** Do not
commit there again without him saying so.

### Review and feedback route

Brian is on **blue**, not red. He cannot see anything rendered on red, and files
pushed through the session's own file-attachment channel did not reach him.

**The route is a published page:** write into `/srv/www/images/<dir>/` and it is
live. The current page is `/srv/www/images/clarity-icons/`, live at
**https://images.hanquest.com:62280/clarity-icons/** (TLS, basic auth, user
`bairui`; the port cannot be dropped — 80/443 are blocked inbound by the ISP).
Built by a script currently only in this session's scratchpad — **if that page
matters, move the builder into this repo.**

Two traps, both hit:
- That slot is published by the images session with
  `rsync -a --delete out/review-web/ /srv/www/images/`, so **their next publish
  erases the clarity-icons directory.** Never rsync `--delete` into that slot.
- **A 401 is not proof a file is served.** Caddy's `basic_auth` fires before the
  file lookup, so an existing path and a missing one both return 401. What can
  be verified from red: the files are on disk under the served root, every
  `<img src>` resolves, and the comment sink answers 200 on `127.0.0.1:8790`.

Every item on the page carries its own comment box (fleet standard). Brian's
comments arrive as `decisions-clarity-*` and are **relayed by images-monitor**;
they land in `hanquest-images/requests/` because `comment-server.py` has no
`clarity` slot. Adding one is a the-den change needing Brian's ask — **offered,
not yet answered.** Read the sink directly rather than trusting a relay:
`curl -s --noproxy '*' "http://127.0.0.1:8790/_api/comments?slot=images&path=decisions/<slug>"`
— the relay has arrived incomplete (2 of 4 comments) at least once.

### Decisions Brian has made

- **Style: the `outline` arm** — "so far outline is the clear winner". Measured,
  it is not true line art: 28.2 mean pixel difference from the plain `flat` arm,
  i.e. a vector illustration with a visible dark stroke.
- **Model: dev.** His eye chose flux1-dev over schnell against the metric
  verdict, which had put schnell ahead on legibility, ink and speed. **His eye
  overrides the metric when they disagree.**
- **The licence question is dead.** flux1-dev is BFL Non-Commercial, but
  *"Clarity is private, ships nowhere"* — so dev is unconstrained. Strike this
  from any future trade-off; it was the only non-quality argument for schnell.

### The live question — HOLD

Brian, on the finished A/B: *"They are both not amazing. Are we using a good
model for this? This feels like the same mistakes we were making before."*
**The 479 render is HELD pending an approach decision.** Do not author the 479
descriptions or start a render until he answers.

**My recommendation, published on the page and unanswered:** the fault is not
the model — it is the category of tool. An icon set is a *system*, and diffusion
cannot hold a system; every round has treated 479 icons as 479 independent
illustration problems, when what makes a set a set is shared invariants (one
stroke weight, one grid, one level of detail, one optical size).

Evidence measured on this batch alone:
- six style arms collapsed into two families
- "a bold line drawing" returned a pencil sketch about a third of the time
- the same prompt gave 0.5% ink on dev and 11.9% on schnell
- `decrease` drew a *rising* arrow; `wifi` drew a blob

Proposed instead: build on a drawn vector base. **Tabler Icons** (MIT, 5,130
icons, one 24px grid, one stroke weight), tinted per category the way the app
already colours its chips. Measured coverage against all 479 names using the
tags in `iconObjects.dart`: **128 exact, 184 via tags (65% auto-mapped), 82
probable needing an eye, 85 with no candidate** (bagel, bakery, bathtub, bear,
boxing-glove, burrito, canoe, cheque, aquarium…). The 65% is a floor — Tabler
ships its own tags per SVG and the match used names only. The trade is losing
colourful illustration for a coherent system.

---

## Hard-won facts worth not re-deriving

- **~40 glyph-shaped names must be drawn, not prompted** (wifi, decrease,
  increase, play-button, arrows, target). A direction and an arc count are
  *facts*; the model returns the nearest familiar thing. No checkpoint fixes it.
- **Colours must be named per subject** or the whole catalogue comes back
  terracotta (measured mean R−B of +45 to +77 across every arm).
- **Render on white, not a magenta chroma key.** The field came back RGB
  (235, 80, 133) and dragged subjects pink in four of six arms; the key then ate
  red artwork. `alpha_for`/`flood_from_border` from `budget/tool/process_pixel_art.py`
  is the working knockout, but its strict fallback is a fixed 246 tuned for pure
  white — measure the page off the border ring instead, or paler arms keep the
  whole backdrop.
- **FluxGuidance is inert on schnell** — proven from the checkpoint header, not
  guessed: schnell has no `guidance_in` tensors (the only 4 keys dev has and it
  lacks). On a schnell arm: steps 4 not 24, and drop the node.
- **A safetensors header parses and reports every prefix on a 21%-downloaded
  file**, and ComfyUI lists it as loadable. Completeness is
  `size >= 8 + header_len + max(data_offsets[1])`, never the header alone.
- **Do not use "interior gradient" as a flatness metric.** A bolder stroke
  raises it exactly as shading does, so it scores against the bolder arm for the
  wrong reason.
- **GPU lock:** only `flock` failing is evidence of busy; only a first-act marker
  file is evidence a command ran; `/srv/gpu.holder` is a note and evidence of
  neither. `gpu-lock.sh` writes the holder four lines *after* taking the flock
  and truncates it in an EXIT trap while fd 9 is still open.

## Peers

`core-monitor` and `images-monitor` run in this tmux session. **Reach them by
name, never by window index** — indices renumber, and a wrong one silently
captures a different agent's pane.
