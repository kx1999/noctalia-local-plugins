# Extent OSD

Shows a Noctalia OSD popup whenever the focused Umbriel window's primary or
secondary extent changes — `window-cycle-*-extent`, `window-modify-*-extent`,
`window-set-*-extent`, `window-modify-width-*/height-*`, or a mouse resize.

The popup names the on-screen side that changed. Tiled windows show their
extent as a percentage with a progress bar (`Width 50%`, `Height 100%`);
floating windows show pixels (`Width 1200px`), since their sizes aren't tied
to the output. When both axes change (a corner drag) the popup uses
width × height notation with a diagonal icon — `1200 × 1200 px` or
`50% × 100%` — because Noctalia's OSD pill has a fixed width (about 25
characters) that plugins can't change.

During a drag, once both axes have changed within *Combine axes window*
(300 ms) the popup stays in the combined form instead of flickering between
width-only and height-only as individual motion events arrive.

## Width / height on any display

Primary and secondary extents map to different screen axes depending on the
layout and on the output's workspace axis (a scrolling strip on a vertical
workspace axis runs sideways, on a horizontal one it runs top-to-bottom). The
plugin sidesteps that by watching which side of the window actually changed,
so the label is always the physical direction you see.

Percentages are measured against the same side of the window's output. Each
output's `transform` and logical size come from Umbriel's event stream, so
rotated/portrait monitors (`90`, `270`, `flipped-90`, `flipped-270`) measure
width against the portrait width automatically, and rotating an output
mid-session doesn't trigger a popup.

## How the percentage is derived

Umbriel doesn't publish extent fractions, so they're derived from geometry the
way Umbriel lays windows out:

```
fraction = (outer + gap) / (usable - 2*gap + gap)     (tiled windows only)
outer   = size + 2*border (+ title bar height, for height)
```

## Settings

Set *Layout gap*, *Border width*, and *Title bar height* to match your Umbriel
config so percentages land exactly on your presets (defaults 8 / 2 / 28 —
Umbriel's defaults and this machine's config). *Show pixel size*, *Include
floating windows*, and *Minimum change* tune what's shown.

## Test

```sh
noctalia msg plugin kylex/extent-osd:service all test   # preview popup
umbriel msg window-cycle-primary-extent                 # real trigger
```
