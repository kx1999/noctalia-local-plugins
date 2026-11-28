# Spectra

A highly customizable audio visualizer for Noctalia v5, with one bar widget
and one desktop / lock-screen widget. Both offer the same 20 shapes. Colors
follow your Noctalia palette by default, so the visualizer changes with your
theme and wallpaper.

| Entry | ID | Audio source |
| --- | --- | --- |
| Bar widget | `kylex/spectra:bar` | The active media player through `cava` (default), or Noctalia's PipeWire spectrum |
| Desktop / lock-screen widget | `kylex/spectra:desktop` | The active media player (default) or all system audio, through `cava` (one per placed widget) |
| Shape gallery (panel) | `kylex/spectra:gallery` | Built-in demo signal |

Requirements: Noctalia 5.6+ (plugin API 55) and `cava` (`pacman -S cava`).
Following only the active media player (the default) also uses `bash`,
`busctl` (systemd) and `pactl` (pipewire-pulse); the bar widget needs none of
these with **Audio from: All system audio**.

## Shapes

| Linear | | Radial | |
| --- | --- | --- | --- |
| `bars` | Bars | `pulse` | Pulse orb: the core follows the bass, rings follow mids and highs |
| `blocks` | Segmented LED blocks | `radial` | Bars around a circle: outward, inward or both ways |
| `dots` | One floating dot per band | `radial_dots` | Dots orbiting a circle |
| `dot_matrix` | Grid of round LEDs | `circle_wave` | A closed line around a circle |
| `bubbles` | Circles sized by level | `bloom` | Translucent petals |
| `lollipops` | Stems with round heads | `spiral` | Bars along a spiral |
| `peaks` | Falling caps over ghost bars | `rings` | Concentric arc gauges, bass outermost |
| `wave` | Smooth line | | |
| `area` | Filled area under the line | | |
| `text` | Terminal-style `▁▂▃▄▅▆▇█` | | |
| `braille` | Braille dots `⣀⣤⣶⣿` | | |
| `spectrogram` | Scrolling waterfall | | |
| `meter` | Bass / mid / treble meters | | |

Linear shapes can grow from the bottom, the top or the center (mirrored). On a
vertical bar they turn 90°, with the bottom on the left. Radial shapes use a
square tile.

To see every shape at once, animated with your current colors:

```fish
noctalia msg panel-toggle kylex/spectra:gallery
```

## Setup

**Bar:** go to Settings → Bar → Widgets, add **Spectra** (`kylex/spectra:bar`) and
open its settings. Or add it to `settings.toml` directly:

```toml
[widget.spectra]
type = "kylex/spectra:bar"
shape = "bars"
audio_spectrum_bands = 32

# then list "spectra" in a bar section, e.g. [bar.default] start = [..., "spectra"]
```

**Desktop:** run `noctalia msg desktop-widgets-edit` and add **Spectra**.
**Lock screen:** run `noctalia msg lockscreen-widgets-edit` and add **Spectra**. In
the widget's settings you can turn off the host **Background** card if you want
the visualizer to float over the wallpaper.

With **Canvas aspect ratio** on **Auto** (the default), the visualizer fills
the widget box edge to edge at any size. Noctalia doesn't tell a plugin its box
size, so the widget finds its own entry among your placed Spectra widgets by
matching its settings. It then reads that entry's box from the shell config,
and when you resize the box, the widget reloads. Two widgets with identical
settings but different boxes can't be told apart; change any setting on one of
them to fix that. A fixed ratio keeps that proportion and is centered in the
box instead.

Sizes such as spacing and bar width are in canvas units. In these units the
box is 600 wide, or 200 tall if that is the tighter fit (600 tall for radial
shapes).

## Settings

Every setting belongs to one widget instance, so a bar widget, a desktop widget
and a lock-screen widget can each look different.

- **Bar widget:** one list in the Settings window. Shape-specific options only
  appear for the matching shape, and fine-tuning options sit behind **Show
  advanced**.
- **Desktop / lock-screen widget:** the editor's inspector doesn't scroll or
  hide advanced options, so a **Settings page** selector at the top splits the
  settings into pages: Shape & canvas, Spacing & size, Colors, Peaks & glow,
  Response & smoothing, Silence & frame rate, and Audio input (cava). Options
  that only the selected shape uses (radial angles, LED segments, text rows,
  …) are listed at the end of every page. A page shows at most 15 rows,
  compared with 43 in a single list.

| Group | Settings |
| --- | --- |
| Shape & layout | shape, baseline (bottom / center / top), frequency layout (low→high, high→low, mirrored with bass in the center or at the edges, auto), resolution (4–128 bands on the bar, 4–256 on the desktop) |
| Size | bar: length, thickness · desktop: canvas aspect ratio (presets or custom W×H), orientation |
| Spacing | spacing, bar width (0 = fit), corner roundness, minimum size (keeps a quiet baseline visible) |
| Colors | mode (solid, gradient, by level, rainbow, alternate), colors 1–2, optional color 3 (**Use color 3**), rainbow speed, opacity, track / unlit opacity, bar tracks, glow, glow strength |
| Peaks | show, optional own color (**Custom peak color**), thickness, hold time, fall speed (gravity) |
| Shape-specific | LED segments and gap, text rows and font, spectrogram history and scroll rate, ring count, radial direction / inner radius / arc / rotation / spin, spiral turns, line width, fill opacity |
| Dynamics | sensitivity, noise floor, response curve, treble tilt, neighbour spread, rise and fall smoothing (ms) |
| Behaviour | when silent (keep, fade, hide, breathe), silent opacity, silence delay, max frame rate, only while media plays, pause while fullscreen |
| Audio | audio from (active media player / all system audio) · desktop: cava path, input (PipeWire / Pulse), source, cava smoothing, auto sensitivity, frequency range |

Colors accept a palette role (`primary`, `tertiary`, `secondary_container`, …)
or a custom hex value. Roles are re-resolved every second, so automatic
wallpaper and theme changes carry over.

Defaults: pill-shaped bars in a primary → tertiary gradient, no peaks, and the
visualizer fades to 35% opacity after 2 s of silence. The bar widget uses 24
bands at 140 × 20 px. The desktop widget uses 64 bands on a 3:1 canvas.

## IPC

Runtime-only previews. They are not saved and reset on reload:

```fish
set W kylex/spectra:desktop                # or kylex/spectra:bar
noctalia msg plugin $W all shape radial    # any shape id from the table above
noctalia msg plugin $W all next            # cycle shapes (also: prev)
noctalia msg plugin $W all demo            # toggle a synthetic test signal (demo on|off)
noctalia msg plugin $W all reset           # back to the saved settings
noctalia msg plugin $W all info            # log shape / bands / idle state
```

## Audio from the active media player

By default (**Audio from: Active media player**) Spectra shows only the
audio of the player Noctalia itself shows as active (the bar media widget's
choice, honouring `shell.mpris.blacklist`). Games, calls, notifications and
other apps don't move it. With no player, or a player that isn't playing
audio, the visualizer settles into its silent state. **All system audio**
restores the old behaviour: everything you hear (the bar then uses Noctalia's
built-in spectrum again).

How it works: `lib/capture.sh` runs for the widget's lifetime. It asks D-Bus
for the player's process (`GetConnectionUnixProcessID`) and picks the
PipeWire playback stream whose process is that process or one of its children
(browsers and Electron apps play from a child process), preferring one that is
playing. It then runs cava on that stream alone (cava's `source` = the stream's
`object.serial`). The plugin writes the active player's D-Bus name to a small
control file whenever it changes. The script re-resolves only when that file
changes, when `pactl subscribe` reports a playback stream appearing or
disappearing, or when cava exits; otherwise it just waits (about 0.05% of a
core). Noctalia stops the whole process group, and the script removes its files,
when the widget goes away. It needs `bash`, `busctl`, `pactl` and `cava` with
PipeWire input.

## Performance

Noctalia meters every plugin callback at 25 ms of CPU and disables a widget
that keeps exceeding that limit. To do that it reads the thread's CPU clock
(a ~0.4 µs syscall) at every Luau call, return and loop back-edge. In practice
a loop iteration costs about 0.42 µs and a call to a Luau function about
0.86 µs, while the arithmetic inside is nearly free. Spectra's hot paths are
written for that cost model:

- The DSP is one fused, 4×-unrolled loop per frame that parses the split cava
  or host line, shapes, smooths and tracks peaks and silence. Display arrays
  share the analysis arrays when no reordering is needed.
- Shapes write primitive tables directly instead of calling helpers, and copy
  with `table.move` (one C call) instead of loops.
- The canvas packs each run of equal-width (or equal-height) primitives into
  one row (or column) whose `gap` is minus that size. Flex then advances by 0,
  so every child starts at the origin and is placed by translate, without a
  zero-height slot of its own. This halves the nodes the host marshals,
  reconciles and lays out. Props the host defaults are left out.

Measured with `bench` (Luau tree building per frame, plus Noctalia's
`render()` marshalling; 64 bands unless noted):

| Shape | Nodes | CPU per frame |
| --- | --- | --- |
| pulse, rings | 9–11 | about 0.2 ms |
| bars, dots, bloom, radial, spiral | 67–101 | 0.25–0.35 ms |
| bars with peaks and tracks | 195 | about 0.4 ms |
| lollipops, circle wave, meter | 51–133 | 0.3–0.4 ms |
| wave, area (128 bands, by level) | about 165 | about 0.5 ms |
| text (128 bands, rows filling the height) | 4 | about 0.45 ms |
| spectrogram (64 × 21 cells) | 1368 | about 0.5 ms, only when a row scrolls in |
| blocks / dot matrix (64 × 16 cells) | 1091 | about 0.6 ms; unchanged columns are reused |

**Wave and area** use Noctalia's `ui.graph`, which draws the curve per pixel
on the GPU and fades the fill from the baseline up. Spectra adjusts for its
quirks. The graph keeps a padding band above and below the plot, and it hides
its first samples behind a scroll window. So Spectra makes the graph slightly
larger than the box and clips it: the baseline and the first and last bands sit
exactly on the edges. Color modes cut the graph into clipped tiles (columns, or
rows for "by level"), with enough of them that neighbouring colors differ by
less than one 8-bit step.

The graph shader evaluates the curve about 20 times per pixel and series,
over the node's whole area. On a full-screen widget that dominated the GPU, so
every tile is cut down to where the curve can actually paint: the cubic's
overshoot, the line width and anti-aliasing are all accounted for, and the
empty rest is never shaded. Column tiles (gradient, rainbow, alternate, and
8 strips for solid) keep only the height their stretch of curve reaches. "By
level" keeps one tile per color row and clips it sideways to the stretch of
curve that crosses that row. Column tiles get only the samples they read (a
window of the series), placed so they draw exactly the same curve as the full
graph; row tiles keep the full series, because their reach changes every
frame and the host mis-samples a graph whose data shrinks (it keeps the larger
texture but indexes it by the new width). For the same reason a tile's node
key changes whenever its data size could. On the desktop, where the pixel
scale is known, tiles that meet are sized in whole pixels: the host rounds
clip edges outwards, so tiles meeting mid-pixel would paint the shared pixel
row twice. The host's CPU cost grows with the number of graphs, so tiles are
never split further than the colors need.

Measured on a 5120 × 1440 desktop widget (128 bands, by level, 120 fps, demo
signal), compared with the earlier one-graph-per-slice version: the wave's
GPU cost dropped from +30% to +18% busy (+22 W to +13 W), and the shell's main
thread from +4.9 to +3.3 points of a core. Real music, with fewer bands at full
height, gains more. The geometry
self-test re-evaluates the shader's curve and checks that the tiles cover every
pixel the line, its anti-aliasing or the fill can touch.

A very faint fade can still show a few steps on a large widget: at 5% total
alpha (fill opacity × opacity) the fade spans only about 8 brightness levels,
and the graph shader doesn't dither. Keep fill opacity × opacity above about
0.3 for a fade that looks continuous on a big box.

Frames are capped by **Max frame rate** (default 60). Drawing stops completely
once the visualizer has settled into silence. The bar widget drops spectrum
frames above that cap before parsing them; Noctalia's spectrum may run at up to
240 Hz. Each desktop or lock-screen instance runs its own cava, which Noctalia
stops when the widget goes away (on the lock screen, at unlock).

**Pause while fullscreen** (on by default) hides the widget and stops drawing
while a visible fullscreen window (a game, a video) sits on the widget's
output, then resumes when it leaves. Each entry subscribes to the compositor's
window snapshots through `noctalia.compositor.subscribe` (Umbriel; niri and
Hyprland when their payload carries a fullscreen flag), so nothing polls. While
paused, incoming spectrum frames and cava lines are dropped before parsing.
cava itself keeps running so playback resumes instantly. On an unsupported
compositor the option does nothing. A lock-screen instance also pauses if a
fullscreen window stays open behind the lock.

## Development

- `tools/gen_manifest.py` generates `plugin.toml` and `translations/en.json`.
  The bar and desktop entries share almost every setting, so edit the
  `SETTINGS` table there and run `python3 tools/gen_manifest.py`. Keep the
  `DEFAULTS` tables in `lib/bar_entry.luau` and `lib/desktop_entry.luau` in sync.
  Every new desktop setting needs a page in `DESKTOP_PAGE`, unless it is
  gated on `shape`. The generator simulates the inspector for every shape
  and page, and fails if any page would show more than `MAX_DESKTOP_ROWS` rows.
- Layout: `lib/engine.luau` holds the core (settings, frame loop, IPC),
  `lib/dsp.luau` the spectrum processing, `lib/shapes.luau` the shapes,
  `lib/canvas.luau` absolute placement on top of flex (zero-gap runs and
  zero-height slots plus paint-only transforms), and `lib/color.luau` the palette handling.
- Self-tests run inside the gallery panel (open it first) and log to
  `~/.cache/noctalia/noctalia.log`:

  ```fish
  set G kylex/spectra:gallery
  noctalia msg panel-open $G
  # geometry: 2640 shape configurations: every element finite, inside its
  # canvas and laid out at the origin; curve tiles cover the drawn curve
  noctalia msg plugin $G all selftest
  for i in (seq 2700); noctalia msg plugin $G all selftest-step; end
  # entries: bar + desktop logic driven with fake spectrum frames / cava lines
  noctalia msg plugin $G all entrytest
  for i in (seq 250); noctalia msg plugin $G all entrytest-step; end
  # per-frame CPU of one shape: "<shape> [bands] [glow] [px/unit] [key=value ...]"
  noctalia msg plugin $G all bench "blocks 64 0"
  noctalia msg plugin $G all bench "wave 128 0 7.2 color_mode=level view=711x200"
  # the host's metering cost (loop iteration, Luau call, unrolled body)
  noctalia msg plugin $G all bench calibrate
  ```
