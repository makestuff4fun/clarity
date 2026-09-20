# CONTEXT — working state

Durable project facts live in `README.md`. This file is the live working
context: what is in flight, what was decided, and what is waiting on Brian.
It is a **snapshot, not a log** — rewrite it rather than appending.

There is no project `CLAUDE.md` and Brian has said not to assume one. Fleet-wide
rules are in `~/.claude/CLAUDE.md`; cross-session environment quirks live in the
auto-memory (`bairui-environment.md`).

Last updated 2026-09-20.

---

## The job, and where it stands

Brian asked for two things: **a modern readable font** and **a new set of
icons**.

| | state |
|---|---|
| Font | **DONE** — Inter, commit `34be351` |
| 479 category icons | **DONE** — commit `c3114d9` |
| The app's *other* artwork | **NOT STARTED** — still 2026-08-03 pixel art |
| Build verification | **DONE** — Flutter installed on red, commit `31afb6a` |

Everything is committed and pushed; the working tree is clean and nothing is
running.

### Next concrete step: none in flight — wait for Brian

Both things he asked for are delivered and verified. **Do not start the
remaining artwork on your own initiative**; he has not asked for it since the
category icons landed, and the last time this session moved ahead of him on
scope it was the wrong call. If he does ask, the step is: brief the images
session against the slot table below, using `budget/tool/process_pixel_art.py`
as the map of which source image feeds which slot.

### Nothing is currently blocked on Brian

Two questions were open a long time and are now moot. If either resurfaces: the
FLUX.1-dev licence does **not** matter (*"Clarity is private, ships nowhere"*),
and the vector/SVG proposal was never ruled on because it was never needed.

One he never answered, now with no deadline: **there is no `clarity` slot in
`comment-server.py`**, so his feedback on Clarity pages lands in
`hanquest-images/requests/`. Adding one is a `the-den` change that needs his ask.

---

## What is left of the original ask

Only the category icons were replaced. Everything else is still the pixel art
from the retro reskin:

| slot | files | what |
|---|---|---|
| `budget/assets/landing/` | 3 | onboarding illustrations (512px) |
| `budget/assets/images/` | 6 | empty states, no-search results (512px) |
| `budget/android/app/src/main/res/drawable/` | 11 | home-screen widget art, quick-action shortcuts |
| `budget/assets/icon/notification_icon_android*.png` | 2 | notification silhouettes (white-on-tint) |
| `budget/assets/icons/fun/` | 2 | party hat, santa hat — seasonal overlays (256px) |

**The launcher icon is NOT among them** — `budget/assets/icon/icon.png` is the
Clarity lightbulb from commit `9bacd02` and predates the reskin. Do not "fix" it.

`budget/tool/process_pixel_art.py` maps every one of those slots to the source
image that feeds it, so it is the recipe for redoing them. If that work starts,
the art comes from the images session — see *Working with the images session*.

---

## How the icons were made and installed

Art comes from the **images** session on red (ComfyUI + RTX 5090),
`flux1-dev-fp8`, "outline" style. Their handoff is
`hanquest-images/requests/clarity-icon-handoff.md`. Brian judged the set on
2026-09-08: *"90% of the icons are very good, best we've made yet."*

Installed by **`budget/tool/deploy_icons.py`** from
`/srv/outputs/clarity_icons/cut/outline_fixed/`. Read that script before
touching the icons again; three things in it are not guessable:

- **Which variant is canonical is recorded, not inferrable.** Every icon has a
  `_72000` roll; nine have a different canonical variant because Brian picked a
  re-roll. The authority is `/srv/outputs/clarity_icons/rerolls.json` under
  `keeps`. A sibling directory holds nine strays at non-72000 seeds that were
  never re-rolls, so "highest seed wins" would silently ship the wrong picture
  for icons nobody would think to check.
- **`air-hockey` is now `ping-pong`.** Brian renamed the slot on 2026-09-09 —
  the model kept drawing a ping-pong paddle, so he changed the word rather than
  the picture. A category's `iconName` is a **stored filename**, so this orphans
  any database row holding the old one. Verified safe before doing it: zero
  `air-hockey` references in the v48 backup, and Clarity ships nowhere.
- **The script refuses rather than guesses** — it exits if `keeps` is missing, if
  a canonical variant is absent, if names drift beyond the known rename, or if
  any source is a valid PNG with an empty alpha channel (which would ship as an
  invisible icon).

⚠️ There are **several near-identical full 479 sets on disk** (`outline`,
`outline_matte`, `outline_fixed`). Only the handoff distinguishes them. I picked
`outline_matte` by eye first and it was wrong.

---

## Working with the images session

Brian is on **blue**, not red, and **cannot see anything rendered on red**. Files
pushed through this session's own file-attachment channel never reached him —
that failure was silent and cost a day.

**The route is a published page.** Write into `/srv/www/images/<dir>/` and it is
live; never run your own web server. The Clarity page is
`/srv/www/images/clarity-icons/` → **https://images.hanquest.com:62280/clarity-icons/**
(TLS, basic auth as `bairui`; the port cannot be dropped — 80/443 are blocked
inbound by the ISP). Its builder exists only in a session scratchpad; **if that
page matters again, write the builder into this repo first.**

- ⚠️ **A 401 is not proof a file is served.** Caddy's `basic_auth` fires before
  the file lookup, so an existing path and a missing one both return 401. What
  can be verified from red: the files are on disk under the served root, every
  `<img src>` resolves, and the comment sink answers 200 on `127.0.0.1:8790`.
- ⚠️ **Relays arrive incomplete and mis-attributed.** One delivered 2 of 4
  comments; another delivered a different team's ruling as Clarity's. **Read the
  sink directly:**
  `curl -s --noproxy '*' "http://127.0.0.1:8790/_api/comments?slot=images&path=decisions/<slug>"`.
  `decisions/<slug>` is the sink's namespace, not a served path, so a slug never
  says whose page it came from. Querying your own boxes is evidence; reading
  someone else's page is inference.
- Every item on a review page gets **its own comment box** (fleet standard), and
  **separate pages** when two teams' work would otherwise share one — batched
  asks get a single verdict pulled toward the worse item.
- ⚠️ Brian objected to this session committing into **hanquest-images**; three
  commits are still there (`5a6bada9`, `057af2f8`, `13c32f57` on `red-dev`).
  Whether they stay, are reverted, or the generator moves to `budget/tool/` is
  an open decision of his. **Do not commit there again without him saying so.**
- That slot is shared. Never `rsync --delete` into `/srv/www/images/`.

---

## Toolchain on red

Flutter **3.47.5 / Dart 3.13.4** at `~/flutter`; Android SDK 35 **and 36**; JDK
21. `PATH`, `ANDROID_HOME` and the mirror variables are persisted in `~/.bashrc`;
telemetry is off. Build and test commands are in the README.

Two network facts without which none of it works (also in the env memory):

- **`ALL_PROXY=socks5://127.0.0.1:7890` is exported globally and breaks curl** —
  curl prefers it over `HTTPS_PROXY`, and the socks5 form fails while http
  works. Everything returns HTTP 000 until you `unset ALL_PROXY all_proxy`.
- **`storage.googleapis.com` and `services.gradle.org` do not resolve** through
  mihomo's fallback group, and that is where Flutter fetches its Dart SDK,
  engine artifacts, packages and Gradle. Use `storage.flutter-io.cn`,
  `pub.flutter-io.cn`, `mirrors.cloud.tencent.com/gradle/`.

`gradle-wrapper.properties` deliberately still points at the canonical
`services.gradle.org` URL rather than a regional mirror. The distribution was
fetched from Tencent and placed in Gradle's wrapper cache under that URL's key —
an md5 of the URL as a base36 BigInteger. **Verify that algorithm by reproducing
an existing cache directory name before relying on it**; it was confirmed
against the 8.11.1 entry.

Flutter 3.47.5 sets hard Android floors and refuses one gate at a time: Gradle
≥ 8.14.0, AGP ≥ 8.11.1, Kotlin ≥ 2.2.20. While failing on those it prints an
**"AGP 9+" hint that is a red herring** — the real error is the line above it.

Verified on 2026-09-20: `flutter analyze` 0 errors (3366 issues, all pre-existing
lint), `flutter test` all pass including the v48 restore test against the real
export, and `flutter build apk --debug` produces an APK carrying 479 category
PNGs with `ping-pong.png` present, `air-hockey.png` and PixelifySans gone, and
`Inter-Regular.ttf` in.

---

## Hard-won facts, if icon generation ever restarts

Expensive to learn and not visible in the code:

- **~40 glyph-shaped names must be drawn, not prompted** (wifi, decrease,
  increase, play-button, arrows, target). A direction and an arc count are
  *facts*; the model returns the nearest familiar thing — `decrease` came back as
  a *rising* arrow. No checkpoint fixes it.
- **Colours must be named per subject**, or the catalogue comes back a terracotta
  monoculture (measured mean R−B of +45 to +77 across every style arm).
- **Render on white, not a magenta chroma key.** The field came back RGB
  (235, 80, 133) and dragged subjects pink in four of six arms; the key then ate
  red artwork. `alpha_for`/`flood_from_border` in
  `budget/tool/process_pixel_art.py` is the working knockout, but its strict
  fallback is a fixed 246 tuned for pure white — measure the page off the border
  ring instead, or paler arms keep the whole backdrop.
- **Brian's bar is "no WRONG text", not "no text"** — `diner` keeps a legible
  English "Diner" sign because *"if the English is correct it's fine"*. Do not
  "fix" an icon for having readable English on it.
- **Tracing raster to SVG does not rescue 24px** (measured by the images session:
  crisp above ~32px, structurally unable below — there is no stroke weight to
  recover from a raster, only an edge to approximate). "Render with flux, then
  trace it to SVG" is not the compromise it looks like.
- **"Vector" names two opposite things.** Brian killed *a diffusion model
  imitating a vector look* (images' exp-0025). That is not a ruling on a drawn
  SVG library, which he has never been shown.
- **Do not use "interior gradient" as a flatness metric.** A bolder stroke raises
  it exactly as shading does, so it scores against the bolder arm for the wrong
  reason.
- **GPU lock:** only `flock` failing is evidence of busy; only a first-act marker
  file is evidence a command ran; `/srv/gpu.holder` is a note and evidence of
  neither. `gpu-lock.sh` writes the holder four lines *after* taking the flock
  and truncates it in an EXIT trap while fd 9 is still open.

### One conclusion of mine that was wrong, so it is not re-derived

When Brian held the job with *"both not amazing, are we using a good model for
this"*, I argued the fault was the **category** of tool — that an icon set is a
system, that diffusion cannot hold a system, and that the route was a drawn
vector base (Tabler, MIT; measured 65% auto-mapped against the 479 names, 85
with no candidate). The images session instead kept iterating on flux1-dev and
got his best verdict yet, two days later.

The measurements above are real and still hold. The conclusion drawn from them —
that the approach could not be made to work — is refuted by the shipped set.
What it needed was people iterating on it.

---

## Also true, easy to get wrong

- **His eye overrides the metric.** The dev-vs-schnell A/B measured schnell ahead
  on legibility, ink and speed; he chose dev.
- The database schema is **48** and must never be lowered — see README.
- Real backups (`cashew-db-v48-*.sql`) are personal financial data and are
  gitignored. Never commit one.
- `budget/android/build/` and `budget/android/.gradle/` are now gitignored; the
  existing `/build/` rule is anchored to the Flutter project root and misses
  them, so a 200 MB Gradle tree was sitting untracked and stageable.
