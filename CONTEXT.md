# CONTEXT — working state

Durable project facts live in `README.md`. This file is the live working
context: what is in flight, what was decided, and what is waiting on Brian.

Last updated 2026-09-20.

---

## The job

Two things Brian asked for: **a modern readable font**, and **a new set of
icons**.

**Font — DONE**, commit `34be351`. Inter is the default; Pixelify Sans, its two
TTFs and its bundled OFL are gone. See README, *Look and feel*.
~~Not build-verified. Flutter is not installed on red.~~ **Corrected
2026-09-20: Flutter 3.47.5 / Dart 3.13.4 is installed at `~/flutter`** and both
the font and the icon commits are now verified on this box — `flutter analyze`
reports 0 errors, `flutter test` passes (including the v48 restore test against
the real export), and `flutter build apk --debug` produces an APK carrying all
479 new icons and Inter.

Two environment facts that make it work, both persisted in `~/.bashrc`:
- **`storage.googleapis.com` does not resolve through mihomo's fallback group**,
  and that is where Flutter fetches its Dart SDK, engine artifacts and packages.
  `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` and
  `PUB_HOSTED_URL=https://pub.flutter-io.cn` are set; without them `pub get`
  hangs and fails. `services.gradle.org` is unreachable for the same reason —
  Gradle distributions come from `mirrors.cloud.tencent.com/gradle/`.
- **`ALL_PROXY=socks5://127.0.0.1:7890` is set globally and breaks curl**, which
  prefers it over `HTTPS_PROXY`; the http form works and the socks5 form does
  not. Every fetch returns 000 until it is unset. Same trap the lexicon already
  recorded for httpx.

Running the tests needs the sqlite shim: `LD_LIBRARY_PATH=<dir holding a
libsqlite3.so symlink to /lib/x86_64-linux-gnu/libsqlite3.so.0>`, and
`BACKUP=<path to a real v48 export>` un-skips the restore test.

**Category icons — DONE and deployed**, commit `c3114d9`. All 479 replaced with
the flux1-dev outline set Brian judged on 2026-09-08 (*"90% of the icons are very
good, best we've made yet"*). `budget/tool/deploy_icons.py` is the installer.

**The rest of the app's artwork is still the 2026-08-03 pixel art** — that is the
remaining half of "a new set of icons" and nobody has started it:

| slot | files | what |
|---|---|---|
| `budget/assets/images/` | 6 | empty states, no-search results (512px) |
| `budget/assets/landing/` | 3 | onboarding illustrations (512px) |
| `budget/assets/icons/fun/` | 2 | party hat, santa hat — seasonal overlays (256px) |
| `budget/android/app/src/main/res/drawable/` | 11 | home-screen widget art, quick-action shortcuts |
| `budget/assets/icon/notification_icon_android*.png` | 2 | notification silhouettes (white-on-tint) |

The launcher icon itself is NOT pixel art — `budget/assets/icon/icon.png` is the
Clarity lightbulb from commit `9bacd02` and predates the reskin.
`budget/tool/process_pixel_art.py` enumerates every one of these slots and which
source image feeds it, so it is the map for redoing them.

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

Every item on the page carries its own comment box (fleet standard). Sharper
form of the same rule, from hanquest-images-21 on 2026-09-09: **separate PAGES,
not just separate boxes, when two teams' work would otherwise share one.** His
verdicts split cleanly when things are presented apart; batched into one "how's
the icon work looking?" they get a single verdict applied to both, pulled in the
direction of the worse item. Brian's
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

⚠️ **2026-09-09 — a ruling relayed here as ours that is NOT ours. Resolved.**
Brian's "iconset design gets rid of some shadows and svg looks good / Vector game
icons are all awful. No use" was passed to this session as endorsement of the
vector proposal. **It is not about Clarity at all** — confirmed by the peer after
checking: both slugs sit on the images session's own `/inbox-tests/` page, and
the comment answers two of four workflow tests Brian sent *them*.

The method that caught it is the one to repeat: **query your own boxes.**
`clarity-approach-vector` was empty three days after it existed, which is
evidence; inferring from someone else's page is not. `decisions/<slug>` is the
sink's namespace, not a served path, so a slug alone never tells you whose page
it came from.

Two things to carry forward from it:

- **"Vector" names two opposite things and they must not be merged.** What Brian
  killed is a *diffusion model imitating a vector look* (their exp-0025, an
  Illustrious LoRA whose measured defect is painting its own background and
  losing the subject — wrong for a cut-out set by construction). Clarity's
  proposal is a *drawn* SVG library with one stroke weight because a person
  chose it. They share only the word. The peer has written that boundary into
  exp-0025's own record so it travels with the row.
- **Tracing raster to SVG does not rescue 24px** — measured by the images
  session on their vectorise tail: crisp above ~32px, files 10–40× smaller, no
  GPU, *and it fails below that*. Structural, not tunable: there is no stroke
  weight to recover from a raster, only an edge to approximate. So the obvious
  middle path — "render with flux, then trace it to SVG" — is already refuted at
  Clarity's grid size. A drawn library is crisp at 24px because someone chose
  the weight at 24px.

### The approach question — RESOLVED, and not the way I argued

On 2026-09-06 Brian held the job with *"They are both not amazing. Are we using a
good model for this? This feels like the same mistakes we were making before."* I
argued the fault was the category of tool — that an icon set is a system and
diffusion cannot hold one — and proposed a drawn vector base (Tabler, MIT;
measured 65% auto-mapped against the 479 names, 85 with no candidate).

**That is not what happened, and the record should say so.** The images session
kept going on flux1-dev with the outline arm, and the set Brian judged on
2026-09-08 is *"90% of the icons are very good, best we've made yet"* — the
strongest verdict any icon round has had. The consistency problem I measured was
real, but it was fixable within diffusion by people iterating on it, and my
conclusion that it was not is refuted by the shipped set.

Keep the underlying measurements (they are in the section below and still true)
and drop the conclusion. The vector proposal stays available for the remaining
artwork slots if they ever want it, but nothing is waiting on it.

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
